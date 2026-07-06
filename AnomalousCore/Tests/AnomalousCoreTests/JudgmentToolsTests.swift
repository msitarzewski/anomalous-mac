import Testing
import Foundation
@testable import AnomalousCore

@Suite("judgment tools — pre-formatted facts the model can only quote")
struct JudgmentToolFormatterTests {
    private func context(
        histories: [JudgmentContext.MetricHistory] = [],
        baselines: [JudgmentContext.MetricBaseline] = [],
        alsoObserved: [String] = [],
        correlatedStates: [String: String] = [:],
        corpusEntries: [String: KnowledgeEntry] = [:]
    ) -> JudgmentContext {
        JudgmentContext(
            processName: "mysqld",
            histories: histories, baselines: baselines,
            alsoObserved: alsoObserved, correlatedStates: correlatedStates,
            corpusEntries: corpusEntries
        )
    }

    @Test("numbers are quoted exactly — integers stay bare, no grouping separators")
    func numberFormatting() {
        #expect(JudgmentToolFormatter.number(1400.0) == "1400")
        #expect(JudgmentToolFormatter.number(0.2) == "0.2")
        #expect(JudgmentToolFormatter.number(1385.5) == "1385.5")
        #expect(!JudgmentToolFormatter.number(1_400_000).contains(","))
    }

    @Test("history sentence quotes the exact curve values, oldest to newest")
    func historyQuotesExactNumbers() {
        let ctx = context(histories: [
            .init(metric: .wakeupsPerSecond, values: [1398, 1400, 1385.5, 1402], windowSeconds: 600)
        ])
        let sentence = JudgmentToolFormatter.historySentence(forMetricNamed: "wakeups_per_sec", context: ctx)
        #expect(sentence.contains("1398, 1400, 1385.5, 1402"))
        #expect(sentence.contains("mysqld"))
        #expect(sentence.contains("10 minutes"))
    }

    @Test("history is capped to the last points — a long curve can't blow the budget")
    func historyCap() {
        let values = (1...20).map(Double.init)
        let ctx = context(histories: [.init(metric: .cpuPercent, values: values, windowSeconds: 1500)])
        let sentence = JudgmentToolFormatter.historySentence(forMetricNamed: "cpu_percent", context: ctx)
        #expect(sentence.contains("13, 14, 15, 16, 17, 18, 19, 20"))
        #expect(!sentence.contains("12,"))
    }

    @Test("baseline sentence quotes median, count, and a finite deviation")
    func baselineQuotesNumbers() {
        let ctx = context(baselines: [
            .init(metric: .wakeupsPerSecond, stats: RobustStats(median: 0.2, mad: 0.1, count: 42), isSeasonal: true, deviation: 350)
        ])
        let sentence = JudgmentToolFormatter.baselineSentence(forMetricNamed: "wakeups_per_sec", context: ctx)
        #expect(sentence.contains("median 0.2"))
        #expect(sentence.contains("42 observations"))
        #expect(sentence.contains("350 MADs above its baseline"))
        #expect(sentence.contains("seasonal"))
    }

    @Test("infinite deviation reads as words, never 'inf MADs'")
    func infiniteDeviationDefensive() {
        #expect(JudgmentToolFormatter.deviationPhrase(.infinity) == "far above any recorded baseline")
        #expect(JudgmentToolFormatter.deviationPhrase(-.infinity) == "far below any recorded baseline")
        #expect(JudgmentToolFormatter.deviationPhrase(nil) == "no robust baseline was recorded")
        #expect(!JudgmentToolFormatter.deviationPhrase(.infinity).lowercased().contains("inf"))
        let ctx = context(baselines: [
            .init(metric: .wakeupsPerSecond, stats: RobustStats(median: 0.2, mad: 0, count: 30), isSeasonal: false, deviation: .infinity)
        ])
        let sentence = JudgmentToolFormatter.baselineSentence(forMetricNamed: "wakeups_per_sec", context: ctx)
        #expect(sentence.contains("far above any recorded baseline"))
    }

    @Test("unknown metric names answer with the valid vocabulary, not a crash")
    func unknownMetric() {
        // NB: "gpu_percent" was this test's unknown-metric example until
        // Phase 5 made it real vocabulary — the guard now uses a name that
        // stays invented.
        let sentence = JudgmentToolFormatter.historySentence(forMetricNamed: "quantum_flux", context: context())
        #expect(sentence.contains("Unknown metric"))
        #expect(sentence.contains("wakeups_per_sec"))
        #expect(sentence.contains("gpu_percent"))   // the vocabulary answer includes the new dimensions
        #expect(sentence.contains("net_bytes_per_sec"))
    }

    @Test("corpus sentence: known entry carries identity + action + tier")
    func corpusKnown() {
        let entry = KnowledgeEntry(
            processName: "dasd", displayName: "Duet Activity Scheduler",
            whatItIs: "Apple's background-activity scheduler.", ownedBy: "Apple",
            whenHotImplies: "Almost always a wedged scheduling loop.",
            safetyTier: 1, safeAction: "kill — launchd respawns it", worstCase: nil,
            causallyLinked: ["appstoreagent"]
        )
        let sentence = JudgmentToolFormatter.corpusSentence(
            processName: "dasd", context: context(corpusEntries: ["dasd": entry])
        )
        #expect(sentence.contains("background-activity scheduler"))
        #expect(sentence.contains("kill — launchd respawns it"))
        #expect(sentence.contains("safety tier 1"))
        #expect(sentence.contains("appstoreagent"))
    }

    @Test("corpus sentence NEVER asserts ownership — that's a live, observed fact")
    func corpusOmitsOwnership() {
        // Ownership + install source come solely from the sensor's live
        // observation (ownerIsRoot / installSource), injected as a hard fact
        // elsewhere. The corpus must not contradict it — the same binary runs
        // as your user under Homebrew but as a root daemon from a package.
        let entry = KnowledgeEntry(
            processName: "mysqld", displayName: "MySQL Database Server",
            whatItIs: "The MySQL database server.",
            ownedBy: "You (a user-run service)",   // deliberately WRONG-for-root
            whenHotImplies: "Usually a client hammering it.",
            safetyTier: 3, safeAction: nil, worstCase: nil, causallyLinked: []
        )
        let sentence = JudgmentToolFormatter.corpusSentence(
            processName: "mysqld", context: context(corpusEntries: ["mysqld": entry])
        )
        #expect(sentence.contains("MySQL database server"))          // identity kept
        #expect(!sentence.localizedCaseInsensitiveContains("owned by"))
        #expect(!sentence.contains("user-run"))                       // never leaks a fixed owner
    }

    @Test("corpus sentence: safeAction nil means 'no safe intervention', tier stays")
    func corpusNilSafeAction() {
        let entry = KnowledgeEntry(
            processName: "mds", displayName: "Spotlight",
            whatItIs: "Spotlight's metadata server.", ownedBy: "Apple",
            whenHotImplies: "Reindexing.", safetyTier: 3, safeAction: nil,
            worstCase: nil, causallyLinked: []
        )
        let sentence = JudgmentToolFormatter.corpusSentence(
            processName: "mds", context: context(corpusEntries: ["mds": entry])
        )
        #expect(sentence.contains("No safe user intervention"))
        #expect(sentence.contains("safety tier 3"))
    }

    @Test("corpus sentence: unknown process is stated UNKNOWN — never invented")
    func corpusUnknown() {
        let sentence = JudgmentToolFormatter.corpusSentence(processName: "xyzd", context: context())
        #expect(sentence.contains("UNKNOWN"))
        #expect(sentence.contains("Do not invent"))
    }

    @Test("correlated sentence joins alsoObserved and linked-process states")
    func correlated() {
        let ctx = context(
            alsoObserved: ["energy.wakeups (wakeups_per_sec 350 MADs above baseline)"],
            correlatedStates: ["appstoreagent": "flagged this tick at 92% CPU"]
        )
        let sentence = JudgmentToolFormatter.correlatedSentence(context: ctx)
        #expect(sentence.contains("350 MADs above baseline"))
        #expect(sentence.contains("appstoreagent: flagged this tick at 92% CPU"))
        let empty = JudgmentToolFormatter.correlatedSentence(context: context())
        #expect(empty.contains("No correlated observations"))
    }
}

@Suite("grounded instructions — the Phase-2 facts ride verbatim")
struct GroundedInstructionsTests {
    private func anomaly(deviation: Double? = .infinity, score: Double = 0.95) -> Anomaly {
        Anomaly(
            kind: .energyWakeups,
            identity: ProcessIdentity(pid: 42, startAbsTime: 7, executableName: "mysqld"),
            windowSeconds: 600, magnitudeCurve: [1400, 1385, 1402], baselineValue: 0.2,
            detectedAt: .now, drivingMetric: "wakeups_per_sec", baselineDeviation: deviation,
            confidence: Confidence(score: score),
            alsoObserved: ["disk.thrash (disk_bytes_per_sec 12 MADs above baseline)"],
            systemContext: "The whole machine was under serious thermal pressure at detection time."
        )
    }

    @Test("instructions embed driving metric, deviation, confidence, and system context")
    func factsEmbedded() {
        let text = JudgmentEngine.instructions(
            anomaly: anomaly(), entry: nil,
            baselineSentence: "averaged 0.2 wakeups/s for 30 days; now about 1400 per second",
            toolsAvailable: true
        )
        #expect(text.contains("driving metric: wakeups_per_sec"))
        #expect(text.contains("far above any recorded baseline"))
        #expect(text.contains("high (0.95)"))
        #expect(text.contains("serious thermal pressure"))
        #expect(text.contains("disk.thrash (disk_bytes_per_sec 12 MADs above baseline)"))
        #expect(text.contains("UNKNOWN process"))
        // Tool naming — the model must be told what the tools are FOR
        // (tool non-selection is silent).
        #expect(text.contains("processHistory"))
        #expect(text.contains("corpusEntry"))
    }

    @Test("±infinite deviation never leaks 'inf' into instructions")
    func infinityDefensive() {
        let text = JudgmentEngine.instructions(
            anomaly: anomaly(deviation: -.infinity), entry: nil,
            baselineSentence: "b", toolsAvailable: false
        )
        #expect(text.contains("far below any recorded baseline"))
        #expect(!text.contains("inf MADs"))
    }

    @Test("no-context path keeps the pre-Phase-3 instructions shape (no tool talk)")
    func noToolsShape() {
        let text = JudgmentEngine.instructions(anomaly: anomaly(), entry: nil, baselineSentence: "b")
        #expect(!text.contains("processHistory"))
        #expect(text.contains("You compose a diagnosis card"))
    }
}

@Suite("escalation policy — cheap by default, table-driven")
struct EscalationPolicyTests {
    @Test("rung-2 selection table", arguments: [
        // (confidence, hasEntry, tier, verdict, expected)
        (Confidence.Level.high, true, 1, "likely_abnormal", false),  // confident + grounded: stay on-device
        (Confidence.Level.high, false, 3, "likely_abnormal", true), // unknown process: thin grounding
        (Confidence.Level.high, true, 3, "likely_abnormal", true),  // tier-3 explain-only
        (Confidence.Level.low, true, 1, "likely_abnormal", true),   // low detector confidence
        (Confidence.Level.medium, true, 1, "uncertain", true),      // model itself unsure
        (Confidence.Level.medium, true, 2, "likely_abnormal", false),
    ])
    func table(row: (Confidence.Level, Bool, Int, String, Bool)) {
        #expect(EscalationPolicy.shouldUpgradeToPCC(
            confidence: row.0, hasCorpusEntry: row.1, actionSafetyTier: row.2, verdict: row.3
        ) == row.4)
    }
}
