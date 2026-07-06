import Foundation
import IOKit

/// Per-process GPU attribution via the IOKit registry (Phase 5). The AGX
/// accelerator publishes one `AGXDeviceUserClient` node per GPU-using process;
/// each carries `IOUserClientCreator` ("pid N, procname") and an `AppUsage`
/// array whose entries hold `accumulatedGPUTime` — cumulative GPU time in
/// mach-absolute ticks. Δ over ticks = per-process GPU share, the same
/// cumulative-counter pattern as the rusage fields (0 = unknown, rates judged
/// Δ-over-window, never absolute).
///
/// ⚠️ PRIVATE SURFACE — undocumented registry properties, not SPI symbols:
/// this reads only IORegistry properties through fully public IOKit calls, so
/// there is no signature to get wrong (the hung-probe lesson doesn't apply),
/// but the property NAMES and SHAPES are Apple-internal and can change any
/// release. Every read degrades to "absent": a missing/renamed property
/// yields an empty map / nil snapshot, never a crash, and the GPU dimension
/// simply goes dark for that tick.
///
/// Verified on-device (M5 Max, macOS 27.0, AGXAcceleratorG17X, 2026-07-05):
/// 103 clients, 37 with AppUsage, WindowServer/root clients visible
/// UNPRIVILEGED — no helper brokering needed for visibility (both tiers still
/// read it so root-tier samples are complete on their own).
///
/// Budget: GPU clients are FEW (~100 registry nodes, 2 property reads each) —
/// we enumerate IOAccelerator children, never scan the ~900-process table.
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
        /// pid → summed `accumulatedGPUTime` (mach-absolute ticks) across all
        /// of that pid's user clients and command queues. Cumulative — a pid
        /// absent here reads 0 (= unknown) on its sample. Note the sum can
        /// DECREASE when a client closes; the Δ-rate machinery already drops
        /// counter regressions, so that reads as a gap, never a negative rate.
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
                byPID[pid, default: 0] &+= accumulatedGPUTime(of: child)
            }
        }
        return Reading(gpuTimeByPID: byPID, device: device)
    }

    /// "pid 462, WindowServer" → 462. Pure and testable; nil on any shape
    /// drift (a renamed format must silence the dimension, not misattribute).
    public static func parseCreatorPID(_ creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let pid = pid_t(digits), pid > 0 else { return nil }
        return pid
    }

    // MARK: - Registry plumbing (every read fails to zero/absent)

    /// Sum of `accumulatedGPUTime` over the client's `AppUsage` entries (one
    /// per command queue). Missing/reshaped property reads 0 = unknown.
    private static func accumulatedGPUTime(of client: io_registry_entry_t) -> UInt64 {
        guard let usage = property(client, "AppUsage") as? [[String: Any]] else { return 0 }
        var total: UInt64 = 0
        for entry in usage {
            if let ticks = entry["accumulatedGPUTime"] as? UInt64 {
                total &+= ticks
            } else if let ticks = entry["accumulatedGPUTime"] as? Int64, ticks > 0 {
                total &+= UInt64(ticks)
            }
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
