import Foundation

/// One observation of one process at one instant. The collector produces
/// these every sampling tick; detection rules and baselines consume them.
public struct ProcessSample: Sendable, Equatable, Codable {
    public let identity: ProcessIdentity
    public let timestamp: Date
    /// Cumulative CPU time (user + system) in seconds since process start.
    public let cpuTimeSeconds: Double
    /// Resident set size in bytes.
    public let residentBytes: UInt64
    /// Seconds since THIS PROCESS started (from ri_proc_start_abstime) —
    /// per-process, never system uptime; the cputime-ratio rule depends on it.
    public let uptimeSeconds: Double

    public init(identity: ProcessIdentity, timestamp: Date, cpuTimeSeconds: Double, residentBytes: UInt64, uptimeSeconds: Double) {
        self.identity = identity
        self.timestamp = timestamp
        self.cpuTimeSeconds = cpuTimeSeconds
        self.residentBytes = residentBytes
        self.uptimeSeconds = uptimeSeconds
    }
}
