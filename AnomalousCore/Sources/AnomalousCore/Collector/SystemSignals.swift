import Foundation
import Darwin

/// System-wide context, sampled once per tick — the cheap, public,
/// App-Store-safe signals (one sysctl / libc call each). Per-process samples
/// say WHAT a process is doing; this says what the MACHINE was experiencing
/// at the same instant, so judgment (Phase 2) can read a spike under memory
/// pressure differently from the same spike on an idle box.
public struct SystemSignals: Sendable, Equatable, Codable {
    /// Kernel memory-pressure level (`kern.memorystatus_vm_pressure_level`):
    /// 1 = normal, 2 = warning, 4 = critical. 0 = sysctl unreadable (unknown).
    public let memoryPressureLevel: Int
    /// Swap in use / currently provisioned, in bytes (`vm.swapusage`). macOS
    /// grows swap files on demand, so "total" is what exists right now, not a
    /// fixed ceiling — used ≤ total always holds.
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    /// Coarse OS thermal pressure (`ProcessInfo.thermalState`) — the public
    /// signal, no SMC/SPI. Actual sensors are Phase 5 territory.
    public let thermalState: ThermalState
    /// Active CPU core count — the denominator that turns a load average
    /// into "how oversubscribed is this machine".
    public let coreCount: Int
    /// Classic 1/5/15-minute run-queue load averages (`getloadavg`).
    public let loadAverage1: Double
    public let loadAverage5: Double
    public let loadAverage15: Double
    // Phase 5 pro signals — system-scope SPI context, OPTIONAL-graceful: nil
    // whenever the surface is missing/renamed/privileged on this build (the
    // readers live in Sensors.swift / GPUSampler.swift; `read()` stays the
    // cheap public snapshot and the caller stamps these via `withProSignals`).
    /// Hottest SoC die temperature, °C (IOHID sensor grid, sudoless SPI).
    public let socTemperatureCelsius: Double?
    /// Average rail power since the previous tick (IOReport "Energy Model").
    public let railPowerWatts: RailPowerReader.Watts?
    /// Whole-GPU utilization % + GPU-owned unified memory (the accelerator's
    /// own `PerformanceStatistics` — device context for the per-process story).
    public let gpuDeviceUtilizationPercent: Double?
    public let gpuInUseSystemMemoryBytes: UInt64?

    /// Mirrors `ProcessInfo.ThermalState` with pinned raw values so the
    /// signal is Codable and matches the wire vocabulary already used by
    /// the protocol's `thermal_pressure` field (nominal/fair/serious/critical).
    public enum ThermalState: Int, Sendable, Codable {
        case nominal = 0, fair = 1, serious = 2, critical = 3

        /// Pure mapping — testable without touching live hardware state.
        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            // A future case the SDK doesn't know yet can only mean "hotter
            // than the scale we shipped with" — clamp to the top, never hide.
            @unknown default: self = .critical
            }
        }
    }

    public init(
        memoryPressureLevel: Int,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        thermalState: ThermalState,
        coreCount: Int,
        loadAverage1: Double,
        loadAverage5: Double,
        loadAverage15: Double,
        socTemperatureCelsius: Double? = nil,
        railPowerWatts: RailPowerReader.Watts? = nil,
        gpuDeviceUtilizationPercent: Double? = nil,
        gpuInUseSystemMemoryBytes: UInt64? = nil
    ) {
        self.memoryPressureLevel = memoryPressureLevel
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.thermalState = thermalState
        self.coreCount = coreCount
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.socTemperatureCelsius = socTemperatureCelsius
        self.railPowerWatts = railPowerWatts
        self.gpuDeviceUtilizationPercent = gpuDeviceUtilizationPercent
        self.gpuInUseSystemMemoryBytes = gpuInUseSystemMemoryBytes
    }

    /// Copy with the Phase 5 sensor readings stamped on — `read()` stays the
    /// pure, cheap sysctl snapshot; the tick adds whatever the SPI tier
    /// yielded (each independently nil-safe).
    public func withProSignals(
        socTemperatureCelsius: Double?,
        railPowerWatts: RailPowerReader.Watts?,
        gpuDevice: GPUSampler.DeviceSnapshot?
    ) -> SystemSignals {
        SystemSignals(
            memoryPressureLevel: memoryPressureLevel,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes,
            thermalState: thermalState,
            coreCount: coreCount,
            loadAverage1: loadAverage1,
            loadAverage5: loadAverage5,
            loadAverage15: loadAverage15,
            socTemperatureCelsius: socTemperatureCelsius,
            railPowerWatts: railPowerWatts,
            gpuDeviceUtilizationPercent: gpuDevice?.deviceUtilizationPercent,
            gpuInUseSystemMemoryBytes: gpuDevice?.inUseSystemMemoryBytes
        )
    }

    // MARK: - Reading

    /// Snapshot every signal once. Each read degrades independently — a
    /// failed sysctl yields that field's "unknown" default (0), never a nil
    /// snapshot; the tick always gets context, however partial.
    public static func read(processInfo: ProcessInfo = .processInfo) -> SystemSignals {
        let swap = swapUsage()
        var loads = [Double](repeating: 0, count: 3)
        let filled = getloadavg(&loads, 3)
        return SystemSignals(
            memoryPressureLevel: Int(sysctlUInt32("kern.memorystatus_vm_pressure_level") ?? 0),
            swapUsedBytes: swap?.xsu_used ?? 0,
            swapTotalBytes: swap?.xsu_total ?? 0,
            thermalState: ThermalState(processInfo.thermalState),
            coreCount: processInfo.activeProcessorCount,
            loadAverage1: filled >= 1 ? loads[0] : 0,
            loadAverage5: filled >= 2 ? loads[1] : 0,
            loadAverage15: filled >= 3 ? loads[2] : 0
        )
    }

    // MARK: - sysctl plumbing

    static func sysctlUInt32(_ name: String) -> UInt32? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }
}
