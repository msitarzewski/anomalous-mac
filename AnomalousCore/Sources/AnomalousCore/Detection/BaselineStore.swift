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

    /// The baseline fact to ground the judgment layer with — or `nil` when it
    /// would CONTRADICT the anomaly. A chronically-hot process poisons its own
    /// EWMA: a long-stuck `appstoreagent` learns ~117% CPU as "normal", so
    /// prepending "Normally uses about 117% CPU" to a "now 91%" observation
    /// makes the card argue against its own flag ("…is it lower than usual?").
    /// For a sustained-CPU anomaly we therefore only supply the learned
    /// baseline when it frames the process as ELEVATED; otherwise the absolute
    /// observation + the corpus (authoritative for a known process's "normal")
    /// carry the card. `currentCPUPercent` is the anomaly's current reading.
    public func groundingSentence(currentCPUPercent: Double, kind: Anomaly.Kind) -> String? {
        if kind == .sustainedCPU, ewmaCPUPercent >= currentCPUPercent { return nil }
        return sentence
    }
}

/// One metric's bounded reservoir: the last `capacity` per-tick observations
/// (~90 minutes at the 90s cadence). DESIGN CHOICE — reservoir over P²
/// streaming quantiles: median + MAD over a real window are EXACT, and a
/// robust dispersion is the whole point of Phase 2; P² is O(1) memory but
/// cannot produce a MAD without approximating deviations around a drifting
/// median estimate — an approximation of the one number the flag threshold
/// keys on. 60 doubles × 4 metrics per lineage is bounded, cheap to sort
/// (60·log 60 × 4 × ~1000 procs per 90s tick is noise), and persists small.
struct MetricReservoir: Codable, Sendable {
    static let capacity = 60
    var values: [Double] = []

    mutating func add(_ value: Double) {
        values.append(value)
        if values.count > Self.capacity {
            values.removeFirst(values.count - Self.capacity)
        }
    }

    var stats: RobustStats? { RobustMath.stats(values) }
}

/// One seasonal bucket's COMPACT summary — (median, MAD, count) only, never
/// raw samples (12 buckets × 4 metrics per lineage must stay tiny; spec'd
/// in phase-2 "Keep storage small"). Streaming scheme:
///   • The first `warmupSize` observations are kept raw, so the summary is
///     EXACT at the moment the bucket becomes eligible for judgment (the
///     seasonal minimum is the same 5 — no judgment ever reads a cold
///     approximation). The raws are then discarded.
///   • After warm-up, clamped (Huber-style) recursions track drift: the
///     median moves toward each observation by a step bounded to 3 scales —
///     an outlier can nudge the baseline, never yank it (that bounded
///     influence IS the robustness), and the dispersion tracks the clamped
///     absolute deviation.
/// The dispersion recursion converges near the MEAN absolute deviation
/// (≈ 1.18 × MAD for normal data) rather than the exact MAD — a deliberate,
/// conservative bias: a slightly LARGER dispersion estimate shrinks computed
/// deviations, so the approximation can only suppress a flag, never
/// manufacture one.
struct SeasonalSummary: Codable, Sendable {
    static let warmupSize = 5
    /// Slow gain: a bucket sees a handful of observations per day; seasons
    /// drift over weeks, not hours.
    static let gain = 0.1

    var median: Double = 0
    var mad: Double = 0
    var count: Int = 0
    var warmup: [Double] = []

    mutating func add(_ value: Double) {
        count += 1
        if count <= Self.warmupSize {
            warmup.append(value)
            if let exact = RobustMath.stats(warmup) {
                median = exact.median
                mad = exact.mad
            }
            if count == Self.warmupSize { warmup = [] }
            return
        }
        // Scale from the LEARNED baseline only (MAD, floored at 5% of the
        // median's magnitude when MAD collapsed to 0 on identical history) —
        // never from the incoming value, or a huge outlier would widen its
        // own clamp and yank the median (defeating the bounded influence).
        // The one degenerate case, a genuinely flat-ZERO history (idle
        // disk), falls back to 5% of the new value so the estimator isn't
        // stuck at 0 forever: a spike then moves the baseline ≤ 1.5% of
        // itself per observation — anomalous unless it persists for weeks.
        var scale = max(mad, abs(median) * 0.05)
        if scale == 0 { scale = abs(value) * 0.05 }
        let bound = 3 * scale
        let step = min(max(value - median, -bound), bound)
        median += Self.gain * step
        let deviation = min(abs(value - median), bound)
        mad += Self.gain * (deviation - mad)
    }

    var stats: RobustStats { RobustStats(median: median, mad: mad, count: count) }
}

/// All robust state for one lineage: global per-metric reservoirs plus
/// seasonal bucket summaries. Dictionary keys are Strings on purpose —
/// Codable encodes non-String-keyed dictionaries as flat arrays; String keys
/// keep baselines.json inspectable and unknown future keys ignorable.
struct RobustBaselines: Codable, Sendable {
    /// BaselineMetric.rawValue → reservoir.
    var reservoirs: [String: MetricReservoir] = [:]
    /// "\(metric.rawValue)|\(bucketKey)" → summary (bucketKey per SeasonalBucket).
    var seasonal: [String: SeasonalSummary] = [:]
    /// Stale-lineage decay keys on this (see robustTTL).
    var lastSeen: Date = .distantPast
}

/// Persists baselines + flagged process instances across app launches.
/// The store is the reason a relaunch doesn't re-diagnose the same runaway,
/// and the reason "is this normal?" has history to answer with.
/// **Baselines stay local, always** — only anonymous signatures ever leave
/// (memory-bank: privacy posture).
public actor BaselineStore {
    struct Snapshot: Codable {
        var schemaVersion = 2
        var baselines: [String: BaselineStats] = [:]
        var flagged: [FlaggedRecord] = []
        /// Cached diagnosis cards, keyed by "processKey|anomalyKind" — the
        /// same condition on the same process reuses its card verbatim.
        var diagnoses: [String: CachedDiagnosis] = [:]
        /// Phase 2 robust/seasonal state, keyed by lineage (schema v2).
        var robust: [String: RobustBaselines] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case schemaVersion, baselines, flagged, diagnoses, robust
        }

        // Versioned decode: a v1 baselines.json (no `robust` key) must load
        // LOSSLESSLY — EWMAs, flags, and cached cards all carry over; the
        // robust state simply starts warming from scratch. decodeIfPresent
        // throughout so any future additive field degrades the same way
        // (mirrors ProcessSample's resilient-decoding rule).
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            baselines = try c.decodeIfPresent([String: BaselineStats].self, forKey: .baselines) ?? [:]
            flagged = try c.decodeIfPresent([FlaggedRecord].self, forKey: .flagged) ?? []
            diagnoses = try c.decodeIfPresent([String: CachedDiagnosis].self, forKey: .diagnoses) ?? [:]
            robust = try c.decodeIfPresent([String: RobustBaselines].self, forKey: .robust) ?? [:]
        }
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
    /// Robust/seasonal state for a lineage not seen in this long decays at
    /// load — a process absent for a month re-warms from scratch (mirrors
    /// the flag-TTL philosophy; bounds baselines.json against churn).
    public static let robustTTL: TimeInterval = 30 * 86_400
    /// Hard cap on robust lineages — a pathological box (build farms spawn
    /// endless short-lived lineages) must not grow the snapshot unbounded;
    /// the most recently seen win.
    static let robustLineageCap = 2000

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
        // Decay stale robust lineages, then cap the survivors (newest win).
        let staleCutoff = Date.now.addingTimeInterval(-Self.robustTTL)
        snapshot.robust = snapshot.robust.filter { $0.value.lastSeen >= staleCutoff }
        if snapshot.robust.count > Self.robustLineageCap {
            let keep = Set(
                snapshot.robust
                    .sorted { $0.value.lastSeen > $1.value.lastSeen }
                    .prefix(Self.robustLineageCap)
                    .map(\.key)
            )
            snapshot.robust = snapshot.robust.filter { keep.contains($0.key) }
        }
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

    // MARK: - Robust + seasonal baselines (Phase 2)

    /// What one tick's recording hands back for judgment — in the SAME actor
    /// hop (a second round-trip per process per tick would double the actor
    /// traffic on the <0.5% CPU layer for nothing).
    public struct TickJudgment: Sendable {
        /// Per metric: the baseline to judge this tick's value against —
        /// the seasonal bucket when warm, the global reservoir otherwise,
        /// absent entirely when the lineage has no history (warm-up).
        public let baselines: [BaselineMetric: SelectedBaseline]
        /// Lifetime observations recorded for the lineage.
        public let observationCount: Int
    }

    /// Feed one tick's per-metric instantaneous observations (the caller
    /// computes Δ-rates from its own history; unknown metrics are simply
    /// absent) and get back the judgment baselines. Selection happens BEFORE
    /// recording, so a tick's own reading never contaminates the baseline it
    /// is judged against.
    ///
    /// `feedBaselines: false` records NOTHING robust/seasonal (selection
    /// still returned): the caller passes it for currently-flagged
    /// processes, because a runaway that burns for two days must not teach
    /// the baseline that burning is normal — only Phase 4's explicit
    /// "normal for me" acknowledgment may do that. (The legacy EWMA keeps
    /// feeding regardless, exactly as it did pre-Phase-2: it's the "what's
    /// normal" sentence, deliberately slow, and changing its diet here would
    /// silently rewrite shipped card copy.)
    public func recordTick(
        key: String,
        at date: Date,
        observations: [BaselineMetric: Double],
        feedBaselines: Bool = true,
        seasonalMinimum: Int = 5,
        calendar: Calendar = .current
    ) -> TickJudgment {
        if let cpu = observations[.cpuPercent] {
            record(key: key, cpuPercent: cpu, rssMB: observations[.memoryMB] ?? 0)
        }

        var entry = snapshot.robust[key] ?? RobustBaselines()
        entry.lastSeen = date
        let bucket = SeasonalBucket.key(for: date, calendar: calendar)
        var selected: [BaselineMetric: SelectedBaseline] = [:]
        for (metric, value) in observations {
            let seasonalKey = "\(metric.rawValue)|\(bucket)"
            if let choice = SelectedBaseline.select(
                global: entry.reservoirs[metric.rawValue]?.stats,
                bucket: entry.seasonal[seasonalKey]?.stats,
                minimumSeasonalCount: seasonalMinimum
            ) {
                selected[metric] = choice
            }
            guard feedBaselines else { continue }
            var reservoir = entry.reservoirs[metric.rawValue] ?? MetricReservoir()
            reservoir.add(value)
            entry.reservoirs[metric.rawValue] = reservoir
            var summary = entry.seasonal[seasonalKey] ?? SeasonalSummary()
            summary.add(value)
            entry.seasonal[seasonalKey] = summary
        }
        snapshot.robust[key] = entry
        return TickJudgment(
            baselines: selected,
            observationCount: snapshot.baselines[key]?.sampleCount ?? 0
        )
    }

    /// The lineage's global robust stats for one metric (nil = never fed).
    public func robustStats(forKey key: String, metric: BaselineMetric) -> RobustStats? {
        snapshot.robust[key]?.reservoirs[metric.rawValue]?.stats
    }

    /// The lineage's seasonal summary stats for one metric+bucket, if any.
    public func seasonalStats(forKey key: String, metric: BaselineMetric, bucket: String) -> RobustStats? {
        snapshot.robust[key]?.seasonal["\(metric.rawValue)|\(bucket)"]?.stats
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
