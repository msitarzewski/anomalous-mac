import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pre-formats tool output as short plain sentences with the numbers INLINE.
/// The model QUOTES these values — it never recomputes or invents them
/// (the field's proven practice: `"cpu over 7d: 138"`, not raw arrays).
/// Pure and FoundationModels-free so every sentence is unit-testable.
public enum JudgmentToolFormatter {
    /// Human-readable, quotable number: integers stay integers ("1400"),
    /// everything else gets one decimal ("0.2"). NO grouping separators —
    /// a quoted "1400" must survive into the card verbatim.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return value > 0 ? "far above measurable range" : "far below measurable range" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    /// Defensive deviation phrasing: MAD-0 baselines yield ±infinity, which
    /// must read as words, never as "inf MADs" (memory-bank learning).
    public static func deviationPhrase(_ deviation: Double?) -> String {
        guard let deviation else { return "no robust baseline was recorded" }
        guard deviation.isFinite else {
            return deviation > 0
                ? "far above any recorded baseline"
                : "far below any recorded baseline"
        }
        return "\(number(deviation)) MADs \(deviation < 0 ? "below" : "above") its baseline"
    }

    /// The metric's plain-English unit for a sentence.
    static func unit(for metric: BaselineMetric) -> String {
        switch metric {
        case .cpuPercent: return "% CPU"
        case .memoryMB: return "MB of memory"
        case .wakeupsPerSecond: return "interrupt wakeups per second"
        case .diskBytesPerSecond: return "MB/s of disk I/O"
        case .gpuPercent: return "% of the GPU"
        case .networkBytesPerSecond: return "MB/s of network traffic"
        }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return "\(m) minute\(m == 1 ? "" : "s")"
    }

    /// Recent metric curve, capped to the last `maxPoints` values so a
    /// chatty history can never blow the 4k context budget.
    public static func historySentence(
        forMetricNamed metricName: String,
        context: JudgmentContext,
        maxPoints: Int = 8
    ) -> String {
        guard let metric = BaselineMetric(rawValue: metricName) else {
            return "Unknown metric '\(metricName)'. Valid metrics: \(BaselineMetric.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        guard let history = context.history(for: metric), !history.values.isEmpty else {
            return "No recorded \(metric.rawValue) history for \(context.processName)."
        }
        let points = history.values.suffix(maxPoints).map(number).joined(separator: ", ")
        return "\(context.processName) \(unit(for: metric)) over the last \(minutes(history.windowSeconds)), oldest to newest: \(points)."
    }

    /// The robust/seasonal baseline plus how far the flagged value sits from
    /// it — the exact judgment the detector already made, in one sentence.
    public static func baselineSentence(
        forMetricNamed metricName: String,
        context: JudgmentContext
    ) -> String {
        guard let metric = BaselineMetric(rawValue: metricName) else {
            return "Unknown metric '\(metricName)'. Valid metrics: \(BaselineMetric.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        guard let baseline = context.baseline(for: metric) else {
            return "No robust baseline recorded yet for \(context.processName) \(metric.rawValue) — this lineage is still warming up."
        }
        let kind = baseline.isSeasonal ? "seasonal baseline (same time of day and day type)" : "overall baseline"
        return "Usual \(unit(for: metric)) for \(context.processName): median \(number(baseline.stats.median)) from \(baseline.stats.count) observations (\(kind)). The flagged level sits \(deviationPhrase(baseline.deviation))."
    }

    /// Everything correlated with this anomaly: other dimensions of the same
    /// process plus causally-linked processes' current state.
    public static func correlatedSentence(context: JudgmentContext) -> String {
        var parts: [String] = []
        if !context.alsoObserved.isEmpty {
            parts.append("Also observed for \(context.processName): \(context.alsoObserved.joined(separator: "; ")).")
        }
        if !context.correlatedStates.isEmpty {
            let states = context.correlatedStates.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "; ")
            parts.append("Causally linked processes right now — \(states).")
        }
        return parts.isEmpty
            ? "No correlated observations this tick — the anomaly is isolated to the primary metric."
            : parts.joined(separator: " ")
    }

    /// The grounding entry for a named process — from the knowledge map
    /// including pulled corpus entries. An unknown process is stated as
    /// unknown; the model must never invent an identity to fill the gap.
    public static func corpusSentence(processName: String, context: JudgmentContext) -> String {
        guard let entry = context.corpusEntry(for: processName) else {
            return "No corpus entry for '\(processName)' — its identity is UNKNOWN. Do not invent what it is; say it is not recognized and treat with caution (safety tier 3)."
        }
        // Ownership + install source are LIVE, per-process facts the sensor
        // observes (ownerIsRoot / installSource) and injects separately as a
        // hard fact ("Runs as: root/user … do NOT describe ownership any other
        // way"). The corpus describes stable IDENTITY only — it must never
        // assert a live fact. `ownedBy` is deliberately NOT surfaced here: the
        // same binary (mysqld, postgres…) runs as your user under Homebrew but
        // as a root daemon from a native package, and feeding a fixed owner
        // string here contradicted the observed truth.
        var lines = [
            "\(entry.processName) (\(entry.displayName)): \(entry.whatItIs)",
            "When hot: \(entry.whenHotImplies)",
        ]
        if let action = entry.safeAction {
            lines.append("Safe action: \(action) (safety tier \(entry.safetyTier)).")
        } else {
            lines.append("No safe user intervention exists for this process — explain only, offer no action (safety tier \(entry.safetyTier)).")
        }
        if !entry.causallyLinked.isEmpty {
            lines.append("Causally linked: \(entry.causallyLinked.joined(separator: ", ")).")
        }
        return lines.joined(separator: " ")
    }
}

#if canImport(FoundationModels)

// MARK: - Tool-calling rung-1 surface (Foundation Models)
//
// Four tools over the JudgmentContext snapshot. Each returns ONE short
// sentence with the numbers inline; the framework injects it into the
// transcript and the model quotes it. All tools are pure reads — no side
// effects, no reaching outside the snapshot.

/// Recent metric curve for the flagged process.
@available(macOS 26.0, *)
struct ProcessHistoryTool: Tool {
    let context: JudgmentContext

    let name = "processHistory"
    let description = "Recent measured values of one metric for the flagged process, oldest to newest. Use it to see what the process actually did over the detection window."

    @Generable
    struct Arguments {
        @Guide(description: "The metric to read.", .anyOf(["cpu_percent", "memory_mb", "wakeups_per_sec", "disk_bytes_per_sec"]))
        var metric: String
    }

    func call(arguments: Arguments) async throws -> String {
        JudgmentToolFormatter.historySentence(forMetricNamed: arguments.metric, context: context)
    }
}

/// The robust/seasonal baseline and deviation for one metric.
@available(macOS 26.0, *)
struct BaselineTool: Tool {
    let context: JudgmentContext

    let name = "baseline"
    let description = "What is normal for the flagged process on one metric — its recorded baseline and how far the flagged level sits from it."

    @Generable
    struct Arguments {
        @Guide(description: "The metric to read.", .anyOf(["cpu_percent", "memory_mb", "wakeups_per_sec", "disk_bytes_per_sec"]))
        var metric: String
    }

    func call(arguments: Arguments) async throws -> String {
        JudgmentToolFormatter.baselineSentence(forMetricNamed: arguments.metric, context: context)
    }
}

/// Correlated observations: other flagged dimensions + causally-linked
/// processes' state this tick.
@available(macOS 26.0, *)
struct CorrelatedTool: Tool {
    let context: JudgmentContext

    let name = "correlated"
    let description = "Other anomalous dimensions of the flagged process and the current state of causally linked processes."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        JudgmentToolFormatter.correlatedSentence(context: context)
    }
}

/// The grounding (corpus/knowledge-map) entry for a named process.
@available(macOS 26.0, *)
struct CorpusTool: Tool {
    let context: JudgmentContext

    let name = "corpusEntry"
    let description = "The curated identity entry for a named process: what it is, what heat implies, and the safe action. Says UNKNOWN when no entry exists."

    @Generable
    struct Arguments {
        @Guide(description: "Executable name of the process to look up, e.g. 'dasd'.")
        var processName: String
    }

    func call(arguments: Arguments) async throws -> String {
        JudgmentToolFormatter.corpusSentence(processName: arguments.processName, context: context)
    }
}

/// The standard rung-1/rung-2 toolset over one context snapshot.
@available(macOS 26.0, *)
enum JudgmentToolbox {
    static func tools(for context: JudgmentContext) -> [any Tool] {
        [
            ProcessHistoryTool(context: context),
            BaselineTool(context: context),
            CorrelatedTool(context: context),
            CorpusTool(context: context),
        ]
    }
}

#endif
