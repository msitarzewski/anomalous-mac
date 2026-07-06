import Foundation

/// One observation of one process at one instant. The collector produces
/// these every sampling tick; detection rules and baselines consume them.
public struct ProcessSample: Sendable, Equatable, Codable {
    public let identity: ProcessIdentity
    public let timestamp: Date
    /// Cumulative CPU time (user + system) in seconds since process start.
    public let cpuTimeSeconds: Double
    /// Resident set size in bytes — kept as the secondary memory number.
    public let residentBytes: UInt64
    /// Seconds since THIS PROCESS started (from ri_proc_start_abstime) —
    /// per-process, never system uptime; the cputime-ratio rule depends on it.
    public let uptimeSeconds: Double
    /// phys_footprint in bytes — the honest memory number (Activity Monitor's
    /// Memory column) and the PRIMARY memory metric going forward. 0 means
    /// "unknown" (stale helper or pre-V6 kernel): fall back to residentBytes.
    public let physFootprintBytes: UInt64
    /// Lifetime high-water phys_footprint, bytes.
    public let lifetimeMaxPhysFootprintBytes: UInt64
    /// Cumulative disk I/O since process start, bytes.
    public let diskBytesRead: UInt64
    public let diskBytesWritten: UInt64
    /// Cumulative energy since process start (all cores), nanojoules.
    public let energyNanojoules: UInt64
    /// P-core share of the energy (P/E split), nanojoules.
    public let pCoreEnergyNanojoules: UInt64
    /// Cumulative package-idle / interrupt wakeups — the battery-drain signal.
    public let idleWakeups: UInt64
    public let interruptWakeups: UInt64
    /// Retired instructions / CPU cycles — real IPC, busy-work vs spin.
    public let instructions: UInt64
    public let cycles: UInt64
    // Phase 5 pro signals — all cumulative counters, all 0 = unknown
    // (stale helper, SPI dark on this build, or the process simply never
    // touched that subsystem), all judged Δ-over-window only.
    /// Cumulative GPU time in mach-absolute ticks (IOKit AGX client
    /// `accumulatedGPUTime`, summed across the pid's clients/queues).
    public let gpuTimeMachAbs: UInt64
    /// Live / lifetime-max Neural Engine memory footprint, bytes
    /// (`ri_neural_footprint` / `ri_lifetime_max_neural_footprint`, the
    /// rusage v6 tail — free in the syscall we already issue).
    public let neuralFootprintBytes: UInt64
    public let lifetimeMaxNeuralFootprintBytes: UInt64
    /// Cumulative network bytes since the sampler started watching
    /// (NetworkStatistics SPI; per-flow counters folded monotonic per pid).
    public let netBytesIn: UInt64
    public let netBytesOut: UInt64

    public init(
        identity: ProcessIdentity,
        timestamp: Date,
        cpuTimeSeconds: Double,
        residentBytes: UInt64,
        uptimeSeconds: Double,
        physFootprintBytes: UInt64 = 0,
        lifetimeMaxPhysFootprintBytes: UInt64 = 0,
        diskBytesRead: UInt64 = 0,
        diskBytesWritten: UInt64 = 0,
        energyNanojoules: UInt64 = 0,
        pCoreEnergyNanojoules: UInt64 = 0,
        idleWakeups: UInt64 = 0,
        interruptWakeups: UInt64 = 0,
        instructions: UInt64 = 0,
        cycles: UInt64 = 0,
        gpuTimeMachAbs: UInt64 = 0,
        neuralFootprintBytes: UInt64 = 0,
        lifetimeMaxNeuralFootprintBytes: UInt64 = 0,
        netBytesIn: UInt64 = 0,
        netBytesOut: UInt64 = 0
    ) {
        self.identity = identity
        self.timestamp = timestamp
        self.cpuTimeSeconds = cpuTimeSeconds
        self.residentBytes = residentBytes
        self.uptimeSeconds = uptimeSeconds
        self.physFootprintBytes = physFootprintBytes
        self.lifetimeMaxPhysFootprintBytes = lifetimeMaxPhysFootprintBytes
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.energyNanojoules = energyNanojoules
        self.pCoreEnergyNanojoules = pCoreEnergyNanojoules
        self.idleWakeups = idleWakeups
        self.interruptWakeups = interruptWakeups
        self.instructions = instructions
        self.cycles = cycles
        self.gpuTimeMachAbs = gpuTimeMachAbs
        self.neuralFootprintBytes = neuralFootprintBytes
        self.lifetimeMaxNeuralFootprintBytes = lifetimeMaxNeuralFootprintBytes
        self.netBytesIn = netBytesIn
        self.netBytesOut = netBytesOut
    }

    // Resilient decoding (same rule as ProcessIdentity): the app decodes
    // `[ProcessSample]` JSON produced by a possibly-OLDER root helper — a
    // stale daemon keeps running old code until restarted. Every field added
    // after the v0.1 shape decodes to 0 (= unknown) when missing, instead of
    // failing the whole array and silently dropping the entire root tier.
    enum CodingKeys: String, CodingKey {
        case identity, timestamp, cpuTimeSeconds, residentBytes, uptimeSeconds
        case physFootprintBytes, lifetimeMaxPhysFootprintBytes
        case diskBytesRead, diskBytesWritten
        case energyNanojoules, pCoreEnergyNanojoules
        case idleWakeups, interruptWakeups
        case instructions, cycles
        case gpuTimeMachAbs
        case neuralFootprintBytes, lifetimeMaxNeuralFootprintBytes
        case netBytesIn, netBytesOut
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ProcessIdentity.self, forKey: .identity)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        cpuTimeSeconds = try c.decode(Double.self, forKey: .cpuTimeSeconds)
        residentBytes = try c.decode(UInt64.self, forKey: .residentBytes)
        uptimeSeconds = try c.decode(Double.self, forKey: .uptimeSeconds)
        physFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .physFootprintBytes) ?? 0
        lifetimeMaxPhysFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .lifetimeMaxPhysFootprintBytes) ?? 0
        diskBytesRead = try c.decodeIfPresent(UInt64.self, forKey: .diskBytesRead) ?? 0
        diskBytesWritten = try c.decodeIfPresent(UInt64.self, forKey: .diskBytesWritten) ?? 0
        energyNanojoules = try c.decodeIfPresent(UInt64.self, forKey: .energyNanojoules) ?? 0
        pCoreEnergyNanojoules = try c.decodeIfPresent(UInt64.self, forKey: .pCoreEnergyNanojoules) ?? 0
        idleWakeups = try c.decodeIfPresent(UInt64.self, forKey: .idleWakeups) ?? 0
        interruptWakeups = try c.decodeIfPresent(UInt64.self, forKey: .interruptWakeups) ?? 0
        instructions = try c.decodeIfPresent(UInt64.self, forKey: .instructions) ?? 0
        cycles = try c.decodeIfPresent(UInt64.self, forKey: .cycles) ?? 0
        gpuTimeMachAbs = try c.decodeIfPresent(UInt64.self, forKey: .gpuTimeMachAbs) ?? 0
        neuralFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .neuralFootprintBytes) ?? 0
        lifetimeMaxNeuralFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .lifetimeMaxNeuralFootprintBytes) ?? 0
        netBytesIn = try c.decodeIfPresent(UInt64.self, forKey: .netBytesIn) ?? 0
        netBytesOut = try c.decodeIfPresent(UInt64.self, forKey: .netBytesOut) ?? 0
    }
}
