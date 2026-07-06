import Foundation

// The judgment core (Phase 2): the shared math and verdict types that turn
// raw detection into honest judgment — "abnormal FOR THIS PROCESS, AT THIS
// TIME, and here's how sure we are". DetectionRules stays pure per-process
// rules over sample curves; BaselineStore stays the persistence actor; this
// file is the currency both trade in: robust statistics (median + MAD),
// seasonal bucket selection, detector-agreement confidence, and anomaly
// grouping. Pure and stateless throughout — fixture-testable without a live
// system, and portable to other platforms unchanged (cross-platform.md).

/// Robust summary of one metric's history: median + MAD. Plain mean/σ is
/// self-defeating for anomaly hunting — the very anomaly we hunt inflates
/// the mean AND the standard deviation, hiding inside its own distortion;
/// median/MAD resist exactly those outliers (research/anomaly-detection.md,
/// Tier 1 #1).
public struct RobustStats: Sendable, Equatable, Codable {
    public let median: Double
    /// RAW median absolute deviation — multiply by `RobustMath.madConsistency`
    /// for a σ-consistent scale (`RobustMath.deviation` does).
    public let mad: Double
    /// Observations behind the summary — the warm-up gates key on this.
    public let count: Int

    public init(median: Double, mad: Double, count: Int) {
        self.median = median
        self.mad = mad
        self.count = count
    }
}

public enum RobustMath {
    /// Consistency constant: for normally-distributed data σ ≈ 1.4826 × MAD,
    /// so "MADs above baseline" reads on the familiar z-score scale and the
    /// rule multipliers (≥ 8) mean what an SRE expects them to mean.
    public static let madConsistency = 1.4826

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    public static func stats(_ values: [Double]) -> RobustStats? {
        guard let med = median(values) else { return nil }
        let mad = median(values.map { abs($0 - med) }) ?? 0
        return RobustStats(median: med, mad: mad, count: values.count)
    }

    /// Robust z: how many consistency-scaled MADs `value` sits above the
    /// median (negative = below). MAD 0 means the history is perfectly flat —
    /// ANY departure is infinitely abnormal, so return ±infinity and let the
    /// rules' absolute floors carry the judgment (comparisons and the
    /// confidence cap both handle infinity naturally; nothing divides by it).
    public static func deviation(_ value: Double, from stats: RobustStats) -> Double {
        let scaled = stats.mad * madConsistency
        guard scaled > 0 else {
            if value == stats.median { return 0 }
            return value > stats.median ? .infinity : -.infinity
        }
        return (value - stats.median) / scaled
    }
}

/// The metrics baselines are kept for. The rawValues double as the
/// `drivingMetric` vocabulary on Anomaly — ONE name from store to rule to
/// card to escalation payload, so Phase 3's LLM quotes the same fact it was
/// given and can never invent a metric.
public enum BaselineMetric: String, Sendable, Codable, CaseIterable {
    case cpuPercent = "cpu_percent"
    case memoryMB = "memory_mb"
    case wakeupsPerSecond = "wakeups_per_sec"
    case diskBytesPerSecond = "disk_bytes_per_sec"
    // Phase 5 pro-signal dimensions (Δ-rates of the new cumulative counters).
    /// Per-process GPU share, percent of one GPU-second per wall-second
    /// (Δ accumulatedGPUTime; parallel command queues can push it past 100).
    case gpuPercent = "gpu_percent"
    /// Per-process network throughput, bytes/s (in + out).
    case networkBytesPerSecond = "net_bytes_per_sec"
}

/// A baseline chosen for judgment: the seasonal bucket's stats when that
/// bucket has enough history (a nightly backup is judged against previous
/// nights — the Datadog move), the global reservoir otherwise.
public struct SelectedBaseline: Sendable, Equatable {
    public let stats: RobustStats
    /// True when the seasonal bucket was warm enough to be the judge.
    public let isSeasonal: Bool

    public init(stats: RobustStats, isSeasonal: Bool) {
        self.stats = stats
        self.isSeasonal = isSeasonal
    }

    /// The selection rule, pure: the bucket wins iff it holds at least
    /// `minimumSeasonalCount` observations (never judge from a bucket seen
    /// four times); otherwise fall back to the global stats, or nil when the
    /// lineage has no history at all (= the warm-up gate's "no judgment").
    public static func select(
        global: RobustStats?,
        bucket: RobustStats?,
        minimumSeasonalCount: Int = 5
    ) -> SelectedBaseline? {
        if let bucket, bucket.count >= minimumSeasonalCount {
            return SelectedBaseline(stats: bucket, isSeasonal: true)
        }
        return global.map { SelectedBaseline(stats: $0, isSeasonal: false) }
    }
}

/// Hour-of-day × weekday/weekend bucketing — 12 buckets (6 four-hour slots
/// × 2 day types). Coarse on purpose: finer buckets would take weeks to warm
/// up and multiply storage; 4-hour slots separate "nightly backup window"
/// from "work hours" — the seasonality that actually causes false positives.
public enum SeasonalBucket {
    /// e.g. "wd-2" = weekday 08:00–12:00, "we-5" = weekend 20:00–24:00.
    /// Calendar is injectable so the bucket math is testable at fixed dates.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        let dayType = (weekday == 1 || weekday == 7) ? "we" : "wd"
        return "\(dayType)-\(hour / 4)"
    }
}

/// A graded verdict — never a binary alert (the false-positive moat). The
/// score is 0–1; the level buckets it for gating: only `.high` surfaces by
/// default (AppState), medium/low are retained quietly for a future UI and
/// for Phase 4's sensitivity envelope.
public struct Confidence: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable {
        case low, medium, high
    }

    public let score: Double
    public let level: Level

    /// Level thresholds mirror the Watchdog-style ensemble bar the research
    /// settled on: ≥ 0.8 high (surfaces), ≥ 0.5 medium (kept quiet), else low.
    public init(score: Double) {
        let clamped = min(max(score, 0), 1)
        self.score = clamped
        self.level = clamped >= 0.8 ? .high : (clamped >= 0.5 ? .medium : .low)
    }
}

/// Detector-agreement confidence: no single statistical detector fires an
/// alert on its own — rules corroborate each other, magnitude speaks, and
/// machine-wide duress discounts (the process may be the victim, not the
/// culprit).
public enum ConfidenceEngine {
    /// Rules whose own thresholds are already conservative enough to stand
    /// alone: the Phase-1 heritage rules (a 50% lifetime ratio, 80% for 25
    /// minutes, a 16 GB ceiling, a hung event loop) plus the footprint port
    /// of the proven leak rule. Firing at all already means "egregious", so
    /// they start at 0.8 — high on their own, exactly the shipping behavior
    /// (dasd on first launch must never wait for a second opinion).
    static let selfQualifyingKinds: Set<Anomaly.Kind> = [
        .sustainedCPU, .cpuTimeRatio, .rssLeak, .rssCeiling,
        .novelProcess, .appHung, .memoryLeakFootprint,
    ]
    /// Rules whose signal is machine-wide under memory pressure: heavy swap
    /// or compressor churn balloons victims' footprints too.
    static let memoryKinds: Set<Anomaly.Kind> = [.rssLeak, .rssCeiling, .memoryLeakFootprint]

    /// MADs where the magnitude bonus starts (= the Δ-rules' own threshold —
    /// merely clearing the bar earns nothing) and the span over which it
    /// maxes: 24+ MADs is "spectacular", enough for ONE signal to surface
    /// alone (the ~1,400/s busy-poll vs a near-zero baseline is hundreds).
    static let magnitudeOnset = 8.0
    static let magnitudeSpan = 16.0

    /// The formula (documented so dogfood tuning has a map):
    ///
    ///     base       0.8 self-qualifying rule / 0.5 statistical Δ-rule
    ///     agreement  +0.3 per OTHER rule independently firing for the same
    ///                process this tick, capped at +0.4 (2-of-N: two Δ-rules
    ///                agreeing → 0.8 → high)
    ///     magnitude  +0.35 × min((MADs − 8) / 16, 1) — how far above the
    ///                robust baseline, so one spectacular signal reaches
    ///                high without a second rule
    ///     duress     −0.4 for memory rules under machine-wide memory
    ///                pressure (level ≥ 2): under pressure the process may
    ///                be the victim, not the culprit
    ///
    /// Clamped to 0…1; levels at ≥ 0.8 / ≥ 0.5 (see Confidence.init).
    public static func score(
        for anomaly: Anomaly,
        agreeingRules: Int,
        signals: SystemSignals?
    ) -> Confidence {
        var value = selfQualifyingKinds.contains(anomaly.kind) ? 0.8 : 0.5
        value += min(Double(max(agreeingRules, 0)) * 0.3, 0.4)
        if let deviation = anomaly.baselineDeviation, deviation > magnitudeOnset {
            value += 0.35 * min((deviation - magnitudeOnset) / magnitudeSpan, 1)
        }
        if memoryKinds.contains(anomaly.kind), let signals, signals.memoryPressureLevel >= 2 {
            value -= 0.4
        }
        return Confidence(score: value)
    }

    /// Score every candidate for ONE process against the others (agreement =
    /// how many peers fired this tick) and stamp the machine-context note.
    public static func annotate(_ candidates: [Anomaly], signals: SystemSignals?) -> [Anomaly] {
        candidates.map { anomaly in
            var annotated = anomaly
            annotated.confidence = score(for: anomaly, agreeingRules: candidates.count - 1, signals: signals)
            annotated.systemContext = systemContext(for: anomaly, signals: signals)
            return annotated
        }
    }

    /// Machine-wide caveats for the card/triage: thermal duress is NOTED
    /// (≥ serious — the spike may be throttling fallout), memory duress is
    /// noted for memory rules (whose score it also discounted above).
    static func systemContext(for anomaly: Anomaly, signals: SystemSignals?) -> String? {
        guard let signals else { return nil }
        var notes: [String] = []
        if signals.thermalState.rawValue >= SystemSignals.ThermalState.serious.rawValue {
            let word = signals.thermalState == .critical ? "critical" : "serious"
            notes.append("The whole machine was under \(word) thermal pressure at detection time.")
        }
        if memoryKinds.contains(anomaly.kind), signals.memoryPressureLevel >= 2 {
            notes.append("System-wide memory pressure was elevated — this process may be a victim of it rather than the cause.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// Correlation/grouping — the anti-fatigue lever: a menu-bar app must never
/// fire five notifications for one underlying event. Same process, several
/// dimensions → ONE anomaly with a primary + `alsoObserved`; causally-linked
/// processes (the knowledge map's curated pairs) → one grouped insight.
public enum AnomalyGrouper {
    /// Collapse one process's candidates into a single anomaly: the primary
    /// is the highest-confidence candidate (ties keep the FIRST — the rule
    /// chain lists the proven long-window rules before the new Δ-rules);
    /// every other dimension becomes a one-line `alsoObserved` fact.
    public static func collapseSameProcess(_ candidates: [Anomaly]) -> Anomaly? {
        guard var primary = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where candidate.confidence.score > primary.confidence.score {
            primary = candidate
        }
        primary.alsoObserved += candidates
            .filter { $0.kind != primary.kind }
            .map { note(for: $0) }
        return primary
    }

    /// Causally-linked processes flagged in the SAME tick collapse into one
    /// insight (dasd↔appstoreagent — the knowledge map already encodes the
    /// pairs). Highest confidence owns the insight; absorbed anomalies are
    /// returned so the caller can still flag them (or they would refire as
    /// their own card next tick — the exact fatigue this kills).
    /// Trade-off, on purpose: if the primary later resolves while an absorbed
    /// process stays hot, the absorbed one stays quiet until its flag
    /// expires. Curated causal pairs co-move, and the alternative is two
    /// notifications for one underlying event.
    public static func groupCausallyLinked(
        _ anomalies: [Anomaly],
        linked: (ProcessIdentity, ProcessIdentity) -> Bool
    ) -> (kept: [Anomaly], absorbed: [Anomaly]) {
        var kept: [Anomaly] = []
        var absorbed: [Anomaly] = []
        for candidate in anomalies.sorted(by: { $0.confidence.score > $1.confidence.score }) {
            if let owner = kept.firstIndex(where: { linked($0.identity, candidate.identity) }) {
                kept[owner].alsoObserved.append("\(candidate.identity.executableName): \(note(for: candidate))")
                absorbed.append(candidate)
            } else {
                kept.append(candidate)
            }
        }
        return (kept, absorbed)
    }

    /// One terse fact line for a grouped-in observation — quotable by the
    /// card and by Phase 3's explainer, never invented numbers.
    static func note(for anomaly: Anomaly) -> String {
        guard let deviation = anomaly.baselineDeviation, !anomaly.drivingMetric.isEmpty else {
            return anomaly.kind.rawValue
        }
        if deviation.isFinite {
            return "\(anomaly.kind.rawValue) (\(anomaly.drivingMetric) \(Int(deviation.rounded())) MADs above baseline)"
        }
        return "\(anomaly.kind.rawValue) (\(anomaly.drivingMetric) far above a flat baseline)"
    }
}
