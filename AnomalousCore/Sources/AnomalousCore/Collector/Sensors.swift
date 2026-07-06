import Foundation
import Darwin

// Phase 5 system sensors — the SPI tier SystemSignals.swift deliberately
// excluded ("actual sensors are Phase 5 territory"). Two sudoless readers:
// SoC die temperature (IOHIDEventSystemClient) and per-rail power (IOReport
// "Energy Model"). Both are SYSTEM-scope context for systemContext/cards,
// never per-process, and both are optional-graceful: nil when the surface is
// missing, renamed, or privileged on this build — the tick always survives.
//
// SPI discipline (the UnresponsiveProbe house style): every symbol resolved
// via dlopen/dlsym behind runtime checks; a missing symbol disables that
// reader, never crashes. Signatures verified on-device (M5 Max, macOS 27.0,
// 2026-07-05): 77 temperature services readable unprivileged (die sensors
// ~38 °C); IOReport enumerates + subscribes unprivileged but only the
// "GPU Energy" channel accumulates without root on this build — CPU/ANE/DRAM
// rails read 0 unprivileged and therefore stay nil (0 = unknown discipline).

/// SoC temperature via the IOHID sensor grid (AppleVendor usage page 0xff00,
/// usage 5 — the apple_sensors path). Reads the hottest DIE sensor ("tdie*"),
/// excluding the constant "tcal" calibration channels.
public enum SoCTemperature {
    private typealias ClientCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias ClientSetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias ClientCopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias ServiceCopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    /// kIOHIDEventTypeTemperature and its value field (type << 16).
    private static let temperatureEventType: Int64 = 15
    private static let temperatureEventField: Int32 = 15 << 16

    /// Hottest die-sensor reading in °C, or nil when the SPI/grid is
    /// unavailable. Creates a fresh event-system client per read — one
    /// mach connection per 90 s tick, no global state to guard.
    public static func read() -> Double? {
        guard let symbols = resolve() else { return nil }
        guard let client = symbols.create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        symbols.setMatching(client, matching)
        guard let services = symbols.copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        var hottestDie: Double?
        var hottestAny: Double?
        for service in services {
            guard let event = symbols.copyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = symbols.getFloat(event, temperatureEventField)
            guard celsius > -50, celsius < 150 else { continue } // sanity: a sensor, not garbage
            let name = (symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            if name.localizedCaseInsensitiveContains("tcal") { continue } // calibration, not a die temp
            if name.localizedCaseInsensitiveContains("tdie") {
                hottestDie = max(hottestDie ?? -.infinity, celsius)
            }
            hottestAny = max(hottestAny ?? -.infinity, celsius)
        }
        return hottestDie ?? hottestAny
    }

    private struct Symbols {
        let create: ClientCreateFn
        let setMatching: ClientSetMatchingFn
        let copyServices: ClientCopyServicesFn
        let copyProperty: ServiceCopyPropertyFn
        let copyEvent: ServiceCopyEventFn
        let getFloat: EventGetFloatValueFn
    }

    private static func resolve() -> Symbols? {
        // IOHIDEventSystemClient* live in the IOKit framework binary; RTLD_DEFAULT
        // finds them in any image already mapped, with an explicit dlopen as
        // the fallback for a bare (non-GUI) process.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        _ = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(rtldDefault, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEventFn.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: EventGetFloatValueFn.self)
        else { return nil }
        return Symbols(create: create, setMatching: setMatching, copyServices: copyServices,
                       copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }
}

/// CPU/GPU/ANE rail power via IOReport's "Energy Model" group. The channels
/// are cumulative energy counters, so watts = Δenergy/Δwall between
/// consecutive `sample()` calls — the first call primes and returns nil.
///
/// dlopen note (recon 2026-07-05): libIOReport.dylib is NOT on disk at
/// /usr/lib (dyld shared cache) — dlopen still resolves it; never
/// file-existence-check the path.
///
/// A rail reports a number only once its counter has ever moved for us;
/// on this build (unprivileged, macOS 27.0/M5) that means GPU flows and
/// CPU/ANE stay nil — honest absence over a fake zero.
public final class RailPowerReader {
    public struct Watts: Sendable, Equatable, Codable {
        public let cpu: Double?
        public let gpu: Double?
        public let ane: Double?

        public init(cpu: Double?, gpu: Double?, ane: Double?) {
            self.cpu = cpu
            self.gpu = gpu
            self.ane = ane
        }
    }

    private typealias CopyChannelsInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c) (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelGetStringFn = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary?, Int32) -> Int64

    private struct Session {
        let subscription: UnsafeMutableRawPointer
        let channels: CFMutableDictionary
        let createSamples: CreateSamplesFn
        let createDelta: CreateSamplesDeltaFn
        let iterate: IterateFn
        let getName: ChannelGetStringFn
        let getUnit: ChannelGetStringFn
        let getValue: SimpleGetIntegerValueFn
    }

    private var session: Session?
    private var sessionAttempted = false
    private var lastSample: CFDictionary?
    private var lastSampleAt: Date?

    public init() {}

    /// Average watts per rail since the previous call. nil on the priming
    /// call or when IOReport is unavailable; per-rail nil when that rail's
    /// counter has never accumulated for this (unprivileged) reader.
    public func sample(now: Date = .now) -> Watts? {
        guard let session = establishSession() else { return nil }
        guard let currentUnmanaged = session.createSamples(session.subscription, session.channels, nil) else { return nil }
        let current = currentUnmanaged.takeRetainedValue()
        defer {
            lastSample = current
            lastSampleAt = now
        }
        guard let previous = lastSample, let previousAt = lastSampleAt else { return nil }
        let dt = now.timeIntervalSince(previousAt)
        guard dt > 0, let deltaUnmanaged = session.createDelta(previous, current, nil) else { return nil }
        let delta = deltaUnmanaged.takeRetainedValue()

        // Joules per rail out of the delta; unit label scales nJ/uJ/mJ/J.
        var joules: [String: Double] = [:]
        session.iterate(delta) { channel in
            guard let name = session.getName(channel)?.takeUnretainedValue() as String? else { return 0 }
            let value = session.getValue(channel, 0)
            guard value > 0 else { return 0 }
            let unit = (session.getUnit(channel)?.takeUnretainedValue() as String?) ?? ""
            let scale: Double
            switch unit {
            case "nJ": scale = 1e-9
            case "uJ", "µJ": scale = 1e-6
            case "mJ": scale = 1e-3
            case "J": scale = 1
            default: return 0 // unknown unit — never guess an order of magnitude
            }
            joules[name, default: 0] += Double(value) * scale
            return 0 // kIOReportIterOk
        }
        func watts(_ channelNames: [String]) -> Double? {
            let total = channelNames.compactMap { joules[$0] }.reduce(0, +)
            return total > 0 ? total / dt : nil
        }
        return Watts(
            cpu: watts(["CPU Energy"]),
            gpu: watts(["GPU Energy", "GPU0"]),
            ane: watts(["ANE0", "ANE Energy"])
        )
    }

    private func establishSession() -> Session? {
        if let session { return session }
        guard !sessionAttempted else { return nil }
        sessionAttempted = true

        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(lib, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
              let createSamples = symbol("IOReportCreateSamples", as: CreateSamplesFn.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
              let iterate = symbol("IOReportIterate", as: IterateFn.self),
              let getName = symbol("IOReportChannelGetChannelName", as: ChannelGetStringFn.self),
              let getUnit = symbol("IOReportChannelGetUnitLabel", as: ChannelGetStringFn.self),
              let getValue = symbol("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValueFn.self),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil) else { return nil }
        let built = Session(
            subscription: subscription, channels: channels,
            createSamples: createSamples, createDelta: createDelta, iterate: iterate,
            getName: getName, getUnit: getUnit, getValue: getValue
        )
        session = built
        return built
    }
}
