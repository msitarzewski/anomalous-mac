import Foundation

/// Rolling behavioral baseline for one process *lineage* (keyed by bundle ID
/// or executable name — survives process restarts, unlike ProcessIdentity).
/// This is what makes "dasd has averaged 0.1% for 90 days" possible.
public struct BaselineStats: Codable, Sendable {
    /// Exponentially weighted moving averages — cheap, drift-tolerant.
    public var ewmaCPUPercent: Double
    public var ewmaRSSMB: Double
    public var sampleCount: Int
    public var firstSeen: Date
    public var lastSeen: Date

    /// Clean, human baseline fact for the judgment layer — no internal
    /// jargon (rule names, sample counts, window sizes). Just "what's normal
    /// for this process."
    public var sentence: String {
        let days = Int(lastSeen.timeIntervalSince(firstSeen) / 86_400)
        let span = days >= 1 ? "over the last \(days) day\(days == 1 ? "" : "s")" : "so far"
        let cpu = ewmaCPUPercent < 1 ? String(format: "%.1f%%", ewmaCPUPercent) : "\(Int(ewmaCPUPercent))%"
        return "Normally uses about \(cpu) CPU and \(Int(ewmaRSSMB)) MB \(span)."
    }
}

/// Persists baselines + flagged process instances across app launches.
/// The store is the reason a relaunch doesn't re-diagnose the same runaway,
/// and the reason "is this normal?" has history to answer with.
/// **Baselines stay local, always** — only anonymous signatures ever leave
/// (memory-bank: privacy posture).
public actor BaselineStore {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var baselines: [String: BaselineStats] = [:]
        var flagged: [FlaggedRecord] = []
        /// Cached diagnosis cards, keyed by "processKey|anomalyKind" — the
        /// same condition on the same process reuses its card verbatim.
        var diagnoses: [String: CachedDiagnosis] = [:]
    }

    public struct FlaggedRecord: Codable, Sendable, Hashable {
        public let identity: ProcessIdentity
        public let kind: String
        public let flaggedAt: Date
    }

    /// Flagged records older than this are dropped at load — a runaway
    /// that persists for a week deserves to be re-surfaced.
    public static let flaggedTTL: TimeInterval = 7 * 86_400
    /// EWMA smoothing per ~90s tick: ~1h half-life.
    static let alpha = 0.03

    private let fileURL: URL
    private var snapshot: Snapshot
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.snapshot = Snapshot()
    }

    // MARK: - Lifecycle

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        snapshot = stored
        let cutoff = Date.now.addingTimeInterval(-Self.flaggedTTL)
        snapshot.flagged.removeAll { $0.flaggedAt < cutoff }
    }

    public func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Flag suppression (survives relaunch)

    public func isFlagged(_ identity: ProcessIdentity) -> Bool {
        let cutoff = Date.now.addingTimeInterval(-Self.flaggedTTL)
        // Apply the TTL at query time, not just at load — this is an
        // always-on app that runs for weeks; a week-old runaway must
        // re-surface even without a relaunch.
        return snapshot.flagged.contains { $0.identity == identity && $0.flaggedAt >= cutoff }
    }

    /// Drop expired flags from the in-memory set (call periodically so the
    /// array doesn't grow unbounded across weeks of uptime).
    public func pruneExpiredFlags() {
        let cutoff = Date.now.addingTimeInterval(-Self.flaggedTTL)
        snapshot.flagged.removeAll { $0.flaggedAt < cutoff }
    }

    public func markFlagged(_ identity: ProcessIdentity, kind: Anomaly.Kind) {
        guard !isFlagged(identity) else { return }
        snapshot.flagged.append(FlaggedRecord(identity: identity, kind: kind.rawValue, flaggedAt: .now))
    }

    // MARK: - Baselines

    public static func key(for identity: ProcessIdentity) -> String {
        identity.bundleID ?? identity.executableName
    }

    /// Feed one tick's instantaneous readings (percent CPU since last tick,
    /// resident MB) — the caller computes deltas from its own history.
    public func record(key: String, cpuPercent: Double, rssMB: Double) {
        let now = Date.now
        if var stats = snapshot.baselines[key] {
            stats.ewmaCPUPercent += Self.alpha * (cpuPercent - stats.ewmaCPUPercent)
            stats.ewmaRSSMB += Self.alpha * (rssMB - stats.ewmaRSSMB)
            stats.sampleCount += 1
            stats.lastSeen = now
            snapshot.baselines[key] = stats
        } else {
            snapshot.baselines[key] = BaselineStats(
                ewmaCPUPercent: cpuPercent, ewmaRSSMB: rssMB,
                sampleCount: 1, firstSeen: now, lastSeen: now
            )
        }
    }

    public func baseline(forKey key: String) -> BaselineStats? {
        snapshot.baselines[key]
    }

    // MARK: - Diagnosis card cache

    private static func diagnosisKey(_ processKey: String, _ kind: Anomaly.Kind) -> String {
        "\(processKey)|\(kind.rawValue)"
    }

    public func cachedDiagnosis(processKey: String, kind: Anomaly.Kind) -> CachedDiagnosis? {
        snapshot.diagnoses[Self.diagnosisKey(processKey, kind)]
    }

    public func cacheDiagnosis(_ diagnosis: CachedDiagnosis, processKey: String, kind: Anomaly.Kind) {
        snapshot.diagnoses[Self.diagnosisKey(processKey, kind)] = diagnosis
    }

    public var flaggedCount: Int { snapshot.flagged.count }
}
