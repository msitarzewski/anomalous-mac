import Foundation

/// Everything the judgment tools may read, snapshotted as pure data at the
/// moment the caller decides to judge. Tools NEVER reach into AppState or a
/// live store — the caller composes this once, so tool answers are
/// deterministic for the tick that produced the anomaly, and the whole
/// tool layer is fixture-testable without a live system.
public struct JudgmentContext: Sendable {
    /// A recent, already-downsampled metric curve for the flagged process.
    /// Values are in the metric's human unit (percent, MB, wakeups/s, MB/s),
    /// oldest first — the same convention as `Anomaly.magnitudeCurve`.
    public struct MetricHistory: Sendable {
        public let metric: BaselineMetric
        public let values: [Double]
        public let windowSeconds: TimeInterval

        public init(metric: BaselineMetric, values: [Double], windowSeconds: TimeInterval) {
            self.metric = metric
            self.values = values
            self.windowSeconds = windowSeconds
        }
    }

    /// The robust/seasonal baseline the detector judged against, plus the
    /// observed deviation — the exact numbers, so the model can only quote.
    public struct MetricBaseline: Sendable {
        public let metric: BaselineMetric
        public let stats: RobustStats
        public let isSeasonal: Bool
        /// Consistency-scaled MADs the flagged value sat above the median
        /// (RobustMath.deviation) — may be ±infinity on a flat baseline.
        public let deviation: Double?

        public init(metric: BaselineMetric, stats: RobustStats, isSeasonal: Bool, deviation: Double?) {
            self.metric = metric
            self.stats = stats
            self.isSeasonal = isSeasonal
            self.deviation = deviation
        }
    }

    /// The flagged process (executable name — the corpus key).
    public let processName: String
    /// Recent curves per metric, at most one per metric.
    public let histories: [MetricHistory]
    /// Selected baselines per metric, at most one per metric.
    public let baselines: [MetricBaseline]
    /// Correlated one-line facts grouped into this anomaly (Anomaly.alsoObserved).
    public let alsoObserved: [String]
    /// One-line current state per causally-linked process the caller knows
    /// about this tick (e.g. "appstoreagent: flagged this tick, cpu_percent
    /// 92% averaged over 25 minutes"). Empty when none were observed.
    public let correlatedStates: [String: String]
    /// Grounding entries by process name — the shipped knowledge map merged
    /// with the pulled, verified corpus feed (pulled wins). Includes the
    /// flagged process and its causally-linked processes when known.
    public let corpusEntries: [String: KnowledgeEntry]

    public init(
        processName: String,
        histories: [MetricHistory] = [],
        baselines: [MetricBaseline] = [],
        alsoObserved: [String] = [],
        correlatedStates: [String: String] = [:],
        corpusEntries: [String: KnowledgeEntry] = [:]
    ) {
        self.processName = processName
        self.histories = histories
        self.baselines = baselines
        self.alsoObserved = alsoObserved
        self.correlatedStates = correlatedStates
        self.corpusEntries = corpusEntries
    }

    public func history(for metric: BaselineMetric) -> MetricHistory? {
        histories.first { $0.metric == metric }
    }

    public func baseline(for metric: BaselineMetric) -> MetricBaseline? {
        baselines.first { $0.metric == metric }
    }

    public func corpusEntry(for name: String) -> KnowledgeEntry? {
        corpusEntries[name]
    }
}
