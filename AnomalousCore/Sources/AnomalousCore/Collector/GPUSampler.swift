import Foundation
import IOKit

/// Reads per-process GPU activity from undocumented AGX registry properties
/// through public IOKit calls. `AppUsage` entries are driver accounting records;
/// they are not documented as disjoint queues or a device-capacity fraction.
/// Raw sums retain their historical field representation for compatibility.
/// Unit calibration and client-lifecycle continuity require separate validation.
public enum GPUSampler {
    /// The accelerator's device-level `PerformanceStatistics` — machine-wide
    /// GPU context for SystemSignals (the per-process story is `gpuTimeByPID`).
    public struct DeviceSnapshot: Sendable, Equatable, Codable {
        /// Whole-GPU utilization percentages as the driver reports them.
        public let deviceUtilizationPercent: Double
        public let rendererUtilizationPercent: Double
        public let tilerUtilizationPercent: Double
        /// "In use system memory" — GPU-owned bytes of unified memory.
        public let inUseSystemMemoryBytes: UInt64

        public init(
            deviceUtilizationPercent: Double,
            rendererUtilizationPercent: Double,
            tilerUtilizationPercent: Double,
            inUseSystemMemoryBytes: UInt64
        ) {
            self.deviceUtilizationPercent = deviceUtilizationPercent
            self.rendererUtilizationPercent = rendererUtilizationPercent
            self.tilerUtilizationPercent = tilerUtilizationPercent
            self.inUseSystemMemoryBytes = inUseSystemMemoryBytes
        }
    }

    /// One tick's read: cumulative GPU time per pid + the device snapshot.
    public struct Reading: Sendable {
        /// pid → raw sum of accumulatedGPUTime across visible client entries.
        /// Zero means unavailable. Client creation/removal can change this sum;
        /// a nondecreasing total alone cannot prove continuity of the clients.
        public let gpuTimeByPID: [pid_t: UInt64]
        public let device: DeviceSnapshot?

        public static let empty = Reading(gpuTimeByPID: [:], device: nil)
    }

    /// Enumerate IOAccelerator services (this box: AGXAcceleratorG17X — the
    /// class is generation-suffixed, so ALWAYS match the parent class
    /// `IOAccelerator`) and their AGXDeviceUserClient children. Any failure —
    /// no accelerator, renamed properties, unexpected shapes — returns what
    /// was readable; worst case `.empty`.
    public static func read() -> Reading {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS,
              iterator != 0
        else { return .empty }
        defer { IOObjectRelease(iterator) }

        var byPID: [pid_t: UInt64] = [:]
        var invalidPIDs: Set<pid_t> = []
        var device: DeviceSnapshot?
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            defer { IOObjectRelease(accelerator); accelerator = IOIteratorNext(iterator) }
            if device == nil { device = deviceSnapshot(of: accelerator) }

            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS,
                  children != 0
            else { continue }
            defer { IOObjectRelease(children) }

            var child = IOIteratorNext(children)
            while child != 0 {
                defer { IOObjectRelease(child); child = IOIteratorNext(children) }
                var className = [CChar](repeating: 0, count: 128)
                guard IOObjectGetClass(child, &className) == KERN_SUCCESS,
                      Collector.string(fromCBuffer: className) == "AGXDeviceUserClient",
                      let creator = property(child, "IOUserClientCreator") as? String,
                      let pid = parseCreatorPID(creator)
                else { continue }
                guard let value = accumulatedGPUTime(usage: property(child, "AppUsage") as? [[String: Any]]) else {
                    invalidPIDs.insert(pid)
                    continue
                }
                let sum = byPID[pid, default: 0].addingReportingOverflow(value)
                if sum.overflow { invalidPIDs.insert(pid) }
                else { byPID[pid] = sum.partialValue }
            }
        }
        for pid in invalidPIDs { byPID.removeValue(forKey: pid) }
        return Reading(gpuTimeByPID: byPID, device: device)
    }

    /// "pid 462, WindowServer" → 462. Pure and testable; nil on any shape
    /// drift (a renamed format must silence the dimension, not misattribute).
    public static func parseCreatorPID(_ creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(", "),
              let pid = pid_t(digits), pid > 0 else { return nil }
        return pid
    }

    // MARK: - Registry plumbing (every read fails to zero/absent)

    /// Do not wrap or silently omit a malformed entry: partial sums can look
    /// like resets or spikes when the complete property reappears next tick.
    static func accumulatedGPUTime(usage: [[String: Any]]?) -> UInt64? {
        guard let usage else { return nil }
        var total: UInt64 = 0
        for entry in usage {
            guard let ticks = entry["accumulatedGPUTime"] as? UInt64 else { return nil }
            let sum = total.addingReportingOverflow(ticks)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    private static func deviceSnapshot(of accelerator: io_registry_entry_t) -> DeviceSnapshot? {
        guard let stats = property(accelerator, "PerformanceStatistics") as? [String: Any] else { return nil }
        func number(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
        return DeviceSnapshot(
            deviceUtilizationPercent: number("Device Utilization %"),
            rendererUtilizationPercent: number("Renderer Utilization %"),
            tilerUtilizationPercent: number("Tiler Utilization %"),
            inUseSystemMemoryBytes: (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
