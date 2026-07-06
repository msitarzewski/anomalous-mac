import Testing
import Foundation
@testable import AnomalousCore

// Phase 2 judgment core: robust math, seasonal bucketing/selection,
// detector-agreement confidence, and anomaly grouping. All pure functions —
// fixture-testable without a live system, like DetectionRulesTests.

private func anomaly(
    kind: Anomaly.Kind,
    name: String = "dasd",
    pid: pid_t = 123,
    drivingMetric: String = "cpu_percent",
    deviation: Double? = nil,
    confidence: Confidence = Confidence(score: 1)
) -> Anomaly {
    Anomaly(
        kind: kind,
        identity: ProcessIdentity(pid: pid, startAbsTime: 42, executableName: name),
        windowSeconds: 600,
        magnitudeCurve: [100],
        baselineValue: nil,
        detectedAt: .now,
        drivingMetric: drivingMetric,
        baselineDeviation: deviation,
        confidence: confidence
    )
}

private func signals(memoryPressure: Int = 1, thermal: SystemSignals.ThermalState = .nominal) -> SystemSignals {
    SystemSignals(
        memoryPressureLevel: memoryPressure,
        swapUsedBytes: 0, swapTotalBytes: 0,
        thermalState: thermal,
        coreCount: 16,
        loadAverage1: 1, loadAverage5: 1, loadAverage15: 1
    )
}

@Suite("robust math — median + MAD, the anomaly-resistant baseline")
struct RobustMathTests {
    @Test("median of odd and even counts")
    func medianBasics() {
        #expect(RobustMath.median([3, 1, 2]) == 2)
        #expect(RobustMath.median([1, 2, 3, 4]) == 2.5)
        #expect(RobustMath.median([]) == nil)
    }

    @Test("the z-score-fails case: the outlier can't hide inside its own distortion")
    func outlierResistsSelfMasking() {
        // [1, 2, 3, 4, 100]: the 100 drags the MEAN to 22 and inflates σ so
        // its plain z-score is ~2 — invisible at any sane threshold. The
        // median (3) and MAD (1) don't move, so robustly it's ~65 MADs out.
        let values: [Double] = [1, 2, 3, 4, 100]
        let stats = RobustMath.stats(values)!
        #expect(stats.median == 3)
        #expect(stats.mad == 1)
        let robust = RobustMath.deviation(100, from: stats)
        #expect(robust > 8)

        let mean = values.reduce(0, +) / 5
        let sigma = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 5).squareRoot()
        #expect((100 - mean) / sigma < 3)   // plain z would have missed it
    }

    @Test("all-identical history → MAD 0; departure is infinite, staying put is 0")
    func flatHistoryEdge() {
        let stats = RobustMath.stats([7, 7, 7, 7])!
        #expect(stats.mad == 0)
        #expect(RobustMath.deviation(7, from: stats) == 0)
        #expect(RobustMath.deviation(8, from: stats) == .infinity)
        #expect(RobustMath.deviation(6, from: stats) == -.infinity)
    }

    @Test("the 1.4826 consistency constant puts MADs on the z-score scale")
    func consistencyConstant() {
        let stats = RobustStats(median: 0, mad: 1, count: 10)
        #expect(abs(RobustMath.deviation(1.4826, from: stats) - 1) < 0.0001)
    }
}

@Suite("seasonal bucketing — judge a spike against ITS OWN window's history")
struct SeasonalBucketTests {
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("weekday/weekend split and 4-hour slots")
    func bucketKeys() {
        // 2026-07-06 is a Monday; 2026-07-04 a Saturday; 2026-07-05 a Sunday.
        #expect(SeasonalBucket.key(for: date(2026, 7, 6, 3), calendar: utc) == "wd-0")
        #expect(SeasonalBucket.key(for: date(2026, 7, 6, 9), calendar: utc) == "wd-2")
        #expect(SeasonalBucket.key(for: date(2026, 7, 6, 23), calendar: utc) == "wd-5")
        #expect(SeasonalBucket.key(for: date(2026, 7, 4, 22), calendar: utc) == "we-5")
        #expect(SeasonalBucket.key(for: date(2026, 7, 5, 0), calendar: utc) == "we-0")
    }

    @Test("selection: a warm bucket wins; a cold one falls back to global")
    func selection() {
        let global = RobustStats(median: 2, mad: 1, count: 60)
        let warm = RobustStats(median: 90, mad: 10, count: 5)
        let cold = RobustStats(median: 90, mad: 10, count: 4)

        let seasonal = SelectedBaseline.select(global: global, bucket: warm)
        #expect(seasonal?.isSeasonal == true)
        #expect(seasonal?.stats.median == 90)

        let fallback = SelectedBaseline.select(global: global, bucket: cold)
        #expect(fallback?.isSeasonal == false)
        #expect(fallback?.stats.median == 2)

        #expect(SelectedBaseline.select(global: nil, bucket: cold) == nil)
    }

    @Test("the correctness point: nightly value quiet in its bucket, loud off-hours")
    func nightlySpikeJudgedSeasonally() {
        // The backup window learned ~90; tonight's 95 is unremarkable THERE
        // but would be wildly abnormal against the all-day global of ~2.
        let bucket = RobustStats(median: 90, mad: 10, count: 12)
        let global = RobustStats(median: 2, mad: 1, count: 60)
        #expect(RobustMath.deviation(95, from: bucket) < 8)
        #expect(RobustMath.deviation(95, from: global) > 8)
    }
}

@Suite("seasonal summary — compact (median, MAD, count), exact at warm-up")
struct SeasonalSummaryTests {
    @Test("exact median/MAD the moment the bucket becomes eligible")
    func exactAtWarmup() {
        var summary = SeasonalSummary()
        for value in [10.0, 12, 8, 11, 9] { summary.add(value) }
        #expect(summary.count == 5)
        #expect(summary.median == 10)
        #expect(summary.mad == 1)
        #expect(summary.warmup.isEmpty)   // raws discarded — summaries only
    }

    @Test("identical values → MAD stays exactly 0 through streaming updates")
    func identicalValuesStayFlat() {
        var summary = SeasonalSummary()
        for _ in 0..<20 { summary.add(4) }
        #expect(summary.median == 4)
        #expect(summary.mad == 0)
    }

    @Test("bounded influence: one outlier nudges the baseline, never yanks it")
    func outlierBoundedInfluence() {
        var summary = SeasonalSummary()
        for value in [10.0, 12, 8, 11, 9] { summary.add(value) }
        summary.add(1000)
        // Step is clamped to 3 scales × gain — the median must stay near 10.
        #expect(summary.median < 12)
        #expect(RobustMath.deviation(1000, from: summary.stats) > 8)   // still anomalous
    }

    @Test("genuine regime change converges over many observations")
    func driftConverges() {
        var summary = SeasonalSummary()
        for value in [10.0, 12, 8, 11, 9] { summary.add(value) }
        for _ in 0..<300 { summary.add(100) }
        #expect(summary.median > 50)   // the new normal is being learned
    }
}

@Suite("confidence — detector agreement, magnitude, and machine duress")
struct ConfidenceEngineTests {
    @Test("one statistical Δ-rule at threshold magnitude → medium, no alert")
    func singleStatisticalRuleIsQuiet() {
        let c = ConfidenceEngine.score(for: anomaly(kind: .energyWakeups, deviation: 8), agreeingRules: 0, signals: signals())
        #expect(c.level == .medium)
        #expect(abs(c.score - 0.5) < 0.001)
    }

    @Test("2-of-N: two rules agreeing crosses the surfacing bar")
    func twoRulesAgreeingSurface() {
        let c = ConfidenceEngine.score(for: anomaly(kind: .energyWakeups, deviation: 8), agreeingRules: 1, signals: signals())
        #expect(c.level == .high)
    }

    @Test("a self-qualifying legacy rule alone still surfaces (dasd on first launch)")
    func legacyRuleAloneIsHigh() {
        let c = ConfidenceEngine.score(for: anomaly(kind: .cpuTimeRatio), agreeingRules: 0, signals: signals())
        #expect(c.level == .high)
    }

    @Test("magnitude alone lifts one spectacular signal to high — the busy-poll case")
    func spectacularMagnitudeSurfacesAlone() {
        // ~1,400/s against a near-zero baseline is hundreds of MADs; the
        // founding mechanism must not wait for a second opinion.
        let c = ConfidenceEngine.score(for: anomaly(kind: .energyWakeups, deviation: 300), agreeingRules: 0, signals: signals())
        #expect(c.level == .high)
        // An infinite deviation (flat baseline) behaves the same, no NaNs.
        let flat = ConfidenceEngine.score(for: anomaly(kind: .energyWakeups, deviation: .infinity), agreeingRules: 0, signals: signals())
        #expect(flat.level == .high)
    }

    @Test("machine-wide memory pressure downgrades memory verdicts (victim, not culprit)")
    func memoryPressureDowngrades() {
        let calm = ConfidenceEngine.score(for: anomaly(kind: .memoryLeakFootprint), agreeingRules: 0, signals: signals(memoryPressure: 1))
        #expect(calm.level == .high)
        let duress = ConfidenceEngine.score(for: anomaly(kind: .memoryLeakFootprint), agreeingRules: 0, signals: signals(memoryPressure: 2))
        #expect(duress.level != .high)
        // Non-memory rules are untouched by memory pressure.
        let cpu = ConfidenceEngine.score(for: anomaly(kind: .cpuTimeRatio), agreeingRules: 0, signals: signals(memoryPressure: 4))
        #expect(cpu.level == .high)
    }

    @Test("thermal ≥ serious is NOTED on the anomaly, not scored")
    func thermalContextNoted() {
        let annotated = ConfidenceEngine.annotate(
            [anomaly(kind: .sustainedCPU)],
            signals: signals(thermal: .serious)
        )
        #expect(annotated.first?.systemContext?.contains("thermal") == true)
        #expect(annotated.first?.confidence.level == .high)   // score unchanged
        let calm = ConfidenceEngine.annotate([anomaly(kind: .sustainedCPU)], signals: signals())
        #expect(calm.first?.systemContext == nil)
    }

    @Test("annotate scores each candidate against the others (agreement = peers)")
    func annotateCountsPeers() {
        let annotated = ConfidenceEngine.annotate(
            [anomaly(kind: .energyWakeups, deviation: 8), anomaly(kind: .diskThrash, drivingMetric: "disk_bytes_per_sec", deviation: 8)],
            signals: signals()
        )
        #expect(annotated.count == 2)
        #expect(annotated.allSatisfy { $0.confidence.level == .high })
    }
}

@Suite("grouping — one insight per underlying event, never five notifications")
struct AnomalyGrouperTests {
    @Test("same process, several dimensions → one anomaly with a primary + also-list")
    func sameProcessCollapses() {
        let cpu = anomaly(kind: .sustainedCPU, confidence: Confidence(score: 0.8))
        let wakeups = anomaly(kind: .energyWakeups, drivingMetric: "wakeups_per_sec", deviation: 40, confidence: Confidence(score: 0.85))
        let primary = AnomalyGrouper.collapseSameProcess([cpu, wakeups])
        #expect(primary?.kind == .energyWakeups)              // highest confidence wins
        #expect(primary?.alsoObserved.count == 1)
        #expect(primary?.alsoObserved.first?.contains("sustained_cpu") == true)
    }

    @Test("confidence ties keep the first candidate — the proven long-window rule")
    func tieKeepsRuleOrder() {
        let ratio = anomaly(kind: .cpuTimeRatio, confidence: Confidence(score: 0.8))
        let disk = anomaly(kind: .diskThrash, confidence: Confidence(score: 0.8))
        #expect(AnomalyGrouper.collapseSameProcess([ratio, disk])?.kind == .cpuTimeRatio)
        #expect(AnomalyGrouper.collapseSameProcess([]) == nil)
    }

    @Test("causally-linked processes collapse into one insight; unlinked stay separate")
    func causalGrouping() {
        let dasd = anomaly(kind: .cpuTimeRatio, name: "dasd", pid: 1, confidence: Confidence(score: 0.9))
        let agent = anomaly(kind: .sustainedCPU, name: "appstoreagent", pid: 2, confidence: Confidence(score: 0.8))
        let stranger = anomaly(kind: .sustainedCPU, name: "mysqld", pid: 3, confidence: Confidence(score: 0.8))

        let linked: (ProcessIdentity, ProcessIdentity) -> Bool = { a, b in
            Set([a.executableName, b.executableName]) == Set(["dasd", "appstoreagent"])
        }
        let (kept, absorbed) = AnomalyGrouper.groupCausallyLinked([dasd, agent, stranger], linked: linked)
        #expect(kept.count == 2)                                // dasd insight + mysqld
        #expect(absorbed.map(\.identity.executableName) == ["appstoreagent"])
        let insight = kept.first { $0.identity.executableName == "dasd" }
        #expect(insight?.alsoObserved.first?.contains("appstoreagent") == true)
        #expect(kept.contains { $0.identity.executableName == "mysqld" })
    }
}
