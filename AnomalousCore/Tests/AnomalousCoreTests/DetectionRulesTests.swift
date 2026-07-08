import Testing
import Foundation
@testable import AnomalousCore

// Swift Testing (Apple's recommended framework — projectRules.md #13).
// Detection rules are pure functions: fully testable without a live system.

private func identity(_ name: String = "dasd") -> ProcessIdentity {
    ProcessIdentity(pid: 123, startAbsTime: 42, executableName: name)
}

private func sample(cpuTime: Double, uptime: TimeInterval, rssBytes: UInt64 = 0, name: String = "dasd") -> ProcessSample {
    ProcessSample(identity: identity(name), timestamp: .now, cpuTimeSeconds: cpuTime, residentBytes: rssBytes, uptimeSeconds: uptime)
}

private func samples(cpuPercent: Double, minutes: Int, rssMB: [Double]? = nil) -> [ProcessSample] {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    return (0...minutes).map { minute in
        ProcessSample(
            identity: identity(),
            timestamp: start.addingTimeInterval(Double(minute) * 60),
            cpuTimeSeconds: Double(minute) * 60 * cpuPercent / 100,
            residentBytes: UInt64((rssMB?[min(minute, (rssMB?.count ?? 1) - 1)] ?? 100) * 1_048_576),
            uptimeSeconds: Double(minute) * 60
        )
    }
}

@Suite("cputime/uptime ratio — the rule that catches dasd on first launch")
struct CPUTimeRatioTests {
    @Test("flags a pre-existing runaway: 25 CPU-hours over 41h of PROCESS uptime")
    func flagsTheFoundingIncident() {
        let anomaly = DetectionRules.cpuTimeRatioAnomaly(
            sample: sample(cpuTime: 25 * 3600, uptime: 41 * 3600, rssBytes: 34 * 1024 * 1024 * 1024)
        )
        #expect(anomaly?.kind == .cpuTimeRatio)
    }

    @Test("ignores a busy process that has not been up long enough")
    func respectsMinimumUptime() {
        #expect(DetectionRules.cpuTimeRatioAnomaly(sample: sample(cpuTime: 3000, uptime: 3600)) == nil)
    }

    @Test("ignores normal daemons: high uptime, tiny cpu time")
    func ignoresIdleDaemons() {
        #expect(DetectionRules.cpuTimeRatioAnomaly(sample: sample(cpuTime: 120, uptime: 100 * 3600)) == nil)
    }

    @Test("young runaway is judged on ITS uptime, not the machine's")
    func usesProcessUptimeNotSystemUptime() {
        // 7h-old process burning 90% of its life: flags — regardless of how
        // long the machine has been up (the review-#1 regression guard).
        let anomaly = DetectionRules.cpuTimeRatioAnomaly(sample: sample(cpuTime: 0.9 * 7 * 3600, uptime: 7 * 3600))
        #expect(anomaly?.kind == .cpuTimeRatio)
    }
}

@Suite("instantaneous CPU — the resolution signal that lets a cputime_ratio card heal")
struct InstantaneousCPUTests {
    @Test("reports the current load for a steady process")
    func steadyLoad() {
        let live = DetectionRules.instantaneousCPUPercent(history: samples(cpuPercent: 150, minutes: 10))
        #expect(live != nil)
        #expect(abs((live ?? 0) - 150) < 1)
    }

    @Test("nil with fewer than two samples (can't compute a rate)")
    func needsTwoSamples() {
        #expect(DetectionRules.instantaneousCPUPercent(history: [sample(cpuTime: 100, uptime: 3600)]) == nil)
    }

    @Test("reads ~0% for a once-hot-now-idle process — the signal that heals a cumulative card")
    func healsWhenIdle() {
        // 30 min at 150% CPU, then 6 min idle (cumulative cputime plateaus).
        // The cputime/uptime RATIO is still huge, but the RECENT window reads
        // ~0% — so a cputime_ratio card can finally resolve. This is exactly the
        // dasd-at-0%-after-a-43h-burn case from the field.
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var hist: [ProcessSample] = []
        var cputime = 0.0
        for minute in 0...30 {                 // hot: +1.5 CPU-sec per wall-sec
            cputime += 60 * 1.5
            hist.append(ProcessSample(identity: identity(), timestamp: start.addingTimeInterval(Double(minute) * 60),
                                      cpuTimeSeconds: cputime, residentBytes: 0, uptimeSeconds: Double(minute) * 60))
        }
        for minute in 31...36 {                // idle: cputime flat
            hist.append(ProcessSample(identity: identity(), timestamp: start.addingTimeInterval(Double(minute) * 60),
                                      cpuTimeSeconds: cputime, residentBytes: 0, uptimeSeconds: Double(minute) * 60))
        }
        let live = DetectionRules.instantaneousCPUPercent(history: hist)
        #expect(live != nil)
        #expect((live ?? 99) < 1)              // recent window is idle → heal

        // ...yet the CUMULATIVE ratio rule STILL fires on the latest sample.
        // That divergence is the whole bug: detection (ratio) says "anomalous",
        // resolution must use the instantaneous signal above to let it heal.
        var t = DetectionThresholds(); t.cpuTimeRatioMinimumUptime = 0
        #expect(DetectionRules.cpuTimeRatioAnomaly(sample: hist.last!, thresholds: t) != nil)
    }
}

@Suite("sustained CPU")
struct SustainedCPUTests {
    @Test("flags 150% sustained over 30 minutes")
    func flagsSustained() {
        let anomaly = DetectionRules.sustainedCPUAnomaly(history: samples(cpuPercent: 150, minutes: 30), baseline: 0.1)
        #expect(anomaly?.kind == .sustainedCPU)
        #expect(anomaly?.baselineValue == 0.1)
    }

    @Test("does not flag below the window length")
    func respectsWindow() {
        #expect(DetectionRules.sustainedCPUAnomaly(history: samples(cpuPercent: 150, minutes: 10), baseline: nil) == nil)
    }

    @Test("does not flag normal load")
    func ignoresNormalLoad() {
        #expect(DetectionRules.sustainedCPUAnomaly(history: samples(cpuPercent: 12, minutes: 30), baseline: nil) == nil)
    }
}

@Suite("RSS leak")
struct RSSLeakTests {
    @Test("flags monotonic doubling above the floor")
    func flagsLeak() {
        let rss = (0...30).map { 600.0 + Double($0) * 25 }   // 600 MB → 1350 MB
        let anomaly = DetectionRules.rssLeakAnomaly(history: samples(cpuPercent: 5, minutes: 30, rssMB: rss))
        #expect(anomaly?.kind == .rssLeak)
    }

    @Test("rejects sawtooth growth (caches, GC) as non-monotonic")
    func rejectsSawtooth() {
        let rss = (0...30).map { 600.0 + Double($0 % 2 == 0 ? $0 * 40 : 0) }
        #expect(DetectionRules.rssLeakAnomaly(history: samples(cpuPercent: 5, minutes: 30, rssMB: rss)) == nil)
    }

    @Test("ignores growth below the absolute floor")
    func respectsFloor() {
        let rss = (0...30).map { 40.0 + Double($0) * 4 }     // 40 MB → 160 MB
        #expect(DetectionRules.rssLeakAnomaly(history: samples(cpuPercent: 5, minutes: 30, rssMB: rss)) == nil)
    }
}

// Phase 2 fixture: cumulative-counter samples (wakeups/disk/footprint are
// since-start counters like the real rusage fields; 0 = unknown). Base
// offsets keep counters nonzero from the first sample — a zero read means
// "stale helper", not "process started at zero".
private func counterSamples(
    minutes: Int,
    wakeupsPerSecond: Double = 0,
    diskBytesPerSecond: Double = 0,
    footprintMB: [Double]? = nil,
    rssMB: [Double]? = nil,
    cpuPercent: Double = 5
) -> [ProcessSample] {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    return (0...minutes).map { minute in
        let t = Double(minute) * 60
        let footprint = footprintMB.map { $0[min(minute, $0.count - 1)] } ?? 0
        let rss = rssMB.map { $0[min(minute, $0.count - 1)] } ?? 100
        return ProcessSample(
            identity: identity(),
            timestamp: start.addingTimeInterval(t),
            cpuTimeSeconds: t * cpuPercent / 100,
            residentBytes: UInt64(rss * 1_048_576),
            uptimeSeconds: t,
            physFootprintBytes: UInt64(footprint * 1_048_576),
            diskBytesRead: diskBytesPerSecond > 0 ? UInt64(4096 + t * diskBytesPerSecond / 2) : 0,
            diskBytesWritten: diskBytesPerSecond > 0 ? UInt64(4096 + t * diskBytesPerSecond / 2) : 0,
            interruptWakeups: wakeupsPerSecond > 0 ? UInt64(1000 + t * wakeupsPerSecond) : 0
        )
    }
}

private func baseline(median: Double, mad: Double, count: Int = 60, seasonal: Bool = false) -> SelectedBaseline {
    SelectedBaseline(stats: RobustStats(median: median, mad: mad, count: count), isSeasonal: seasonal)
}

@Suite("baseline grounding — a card must never contradict its own flag")
struct GroundingSentenceTests {
    private func stats(cpu: Double) -> BaselineStats {
        BaselineStats(ewmaCPUPercent: cpu, ewmaRSSMB: 40, sampleCount: 200,
                      firstSeen: Date(timeIntervalSince1970: 1_750_000_000),
                      lastSeen: Date(timeIntervalSince1970: 1_750_090_000))
    }

    @Test("poisoned baseline (learned 117% as normal) is DROPPED for a 91% sustained-CPU flag")
    func poisonedBaselineDropped() {
        // The appstoreagent case: a long-stuck process learned ~117% as its
        // "normal", so grounding a "now 91%" card with it produced "normally
        // 117%, now 91% — is it lower than usual?". Drop it.
        #expect(stats(cpu: 117).groundingSentence(currentCPUPercent: 91, kind: .sustainedCPU) == nil)
    }

    @Test("a genuinely-elevated sustained-CPU anomaly keeps its baseline")
    func elevatedKeepsBaseline() {
        #expect(stats(cpu: 5).groundingSentence(currentCPUPercent: 91, kind: .sustainedCPU) != nil)
    }

    @Test("the guard is CPU-anomaly-specific — a memory/footprint flag still grounds on CPU baseline")
    func guardIsCPUOnly() {
        // A high CPU baseline doesn't contradict a memory-leak card, so keep it.
        #expect(stats(cpu: 117).groundingSentence(currentCPUPercent: 91, kind: .memoryLeakFootprint) != nil)
    }
}

@Suite("energy.wakeups — the founding busy-poll mechanism, detected by mechanism")
struct WakeupsRuleTests {
    @Test("flags the 1ms busy-poll: ~1,400/s sustained against a quiet baseline")
    func flagsBusyPoll() {
        let anomaly = DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400),
            baseline: baseline(median: 5, mad: 2)
        )
        #expect(anomaly?.kind == .energyWakeups)
        #expect(anomaly?.drivingMetric == "wakeups_per_sec")
        #expect((anomaly?.baselineDeviation ?? 0) > 100)   // hundreds of MADs
        #expect(anomaly?.baselineValue == 5)               // the quotable "usual"
    }

    @Test("warm-up gate: a lineage seen 2 ticks never fires, whatever the magnitude")
    func warmUpGate() {
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400),
            baseline: baseline(median: 5, mad: 2, count: 2)
        ) == nil)
    }

    @Test("idle process (the Zed case): high wakeups but ~0% CPU is NOT a battery drain → no card")
    func idleWakeupsDoNotFire() {
        // Same 1,400/s wake spike, but the process sits at ~0% CPU — cheap
        // coalesced wakeups, not a drain. The card would claim it "drains the
        // battery"; that would be false, so the rule must stay quiet.
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400, cpuPercent: 0),
            baseline: baseline(median: 5, mad: 2)
        ) == nil)
        // ...and a busy-poll doing real work (>3% CPU) still fires.
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400, cpuPercent: 40),
            baseline: baseline(median: 5, mad: 2)
        )?.kind == .energyWakeups)
    }

    @Test("no baseline at all (never observed) → no judgment")
    func noBaselineNoJudgment() {
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400),
            baseline: nil
        ) == nil)
    }

    @Test("absolute floor: statistically loud but humanly silent stays silent")
    func respectsFloor() {
        // 80/s is hundreds of MADs above a 0.2/s baseline — and nobody's
        // battery dies at 80 wakeups/s.
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 80),
            baseline: baseline(median: 0.2, mad: 0.1)
        ) == nil)
    }

    @Test("a rate matching the lineage's own noisy history does not flag")
    func matchesOwnHistory() {
        // 1,400/s against a median of 1,200 ± 300: barely half a MAD above.
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 1400),
            baseline: baseline(median: 1200, mad: 300)
        ) == nil)
    }

    @Test("0 = unknown counters (stale helper) are excluded, never a reset")
    func unknownCountersExcluded() {
        // All-zero interruptWakeups: no known readings → no rate → no flag.
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 15, wakeupsPerSecond: 0),
            baseline: baseline(median: 5, mad: 2)
        ) == nil)
    }

    @Test("a burst shorter than the window is not 'sustained'")
    func respectsWindow() {
        #expect(DetectionRules.wakeupsAnomaly(
            history: counterSamples(minutes: 5, wakeupsPerSecond: 1400),
            baseline: baseline(median: 5, mad: 2)
        ) == nil)
    }
}

@Suite("disk.thrash — sustained throughput far above the lineage's baseline")
struct DiskThrashRuleTests {
    @Test("flags 100 MB/s sustained against a near-idle baseline")
    func flagsThrash() {
        let anomaly = DetectionRules.diskThrashAnomaly(
            history: counterSamples(minutes: 15, diskBytesPerSecond: 100 * 1_048_576),
            baseline: baseline(median: 2 * 1_048_576, mad: 1_048_576)
        )
        #expect(anomaly?.kind == .diskThrash)
        #expect(anomaly?.drivingMetric == "disk_bytes_per_sec")
        // Curve and baselineValue are humanized to MB/s.
        #expect(abs((anomaly?.magnitudeCurve.last ?? 0) - 100) < 2)
        #expect(abs((anomaly?.baselineValue ?? 0) - 2) < 0.01)
    }

    @Test("the nightly-backup rate judged against ITS OWN bucket does not flag")
    func seasonalBaselineSuppresses() {
        // Same 100 MB/s that flags above — but the seasonal bucket learned
        // that this window usually runs ~90 MB/s (previous nights). This is
        // the Datadog move: a Monday-2am spike vs previous Mondays at 2am.
        #expect(DetectionRules.diskThrashAnomaly(
            history: counterSamples(minutes: 15, diskBytesPerSecond: 100 * 1_048_576),
            baseline: baseline(median: 90 * 1_048_576, mad: 10 * 1_048_576, seasonal: true)
        ) == nil)
    }

    @Test("heavy but baseline-consistent throughput below the floor stays quiet")
    func respectsFloor() {
        #expect(DetectionRules.diskThrashAnomaly(
            history: counterSamples(minutes: 15, diskBytesPerSecond: 10 * 1_048_576),
            baseline: baseline(median: 100_000, mad: 50_000)
        ) == nil)
    }
}

@Suite("memory.leak_footprint — the honest-memory port of the leak rule")
struct FootprintLeakRuleTests {
    @Test("flags monotonic footprint doubling above the footprint floor")
    func flagsFootprintLeak() {
        // 300 MB → 1050 MB: below the RSS floor (512 MB) at the start, so the
        // legacy rule would have MISSED it — the footprint floor (256 MB)
        // catches it, which is the point of the port.
        let footprint = (0...30).map { 300.0 + Double($0) * 25 }
        let anomaly = DetectionRules.footprintLeakAnomaly(
            history: counterSamples(minutes: 30, footprintMB: footprint)
        )
        #expect(anomaly?.kind == .memoryLeakFootprint)
        #expect(anomaly?.drivingMetric == "memory_mb")
    }

    @Test("stale helper (footprint unknown) falls back to the RSS curve + RSS floor")
    func rssFallback() {
        let rss = (0...30).map { 600.0 + Double($0) * 25 }
        let anomaly = DetectionRules.footprintLeakAnomaly(
            history: counterSamples(minutes: 30, rssMB: rss)   // all footprints 0
        )
        #expect(anomaly?.kind == .memoryLeakFootprint)
        // ...and the RSS floor applies on the fallback path: the same growth
        // starting at 300 MB (fine for footprint) is below the RSS floor.
        let low = (0...30).map { 300.0 + Double($0) * 25 }
        #expect(DetectionRules.footprintLeakAnomaly(history: counterSamples(minutes: 30, rssMB: low)) == nil)
    }

    @Test("mixed-vintage history never splices footprint and RSS into one curve")
    func mixedVintageUsesOneUnit() {
        // Footprint grows 2× but ONE sample lost it (helper restart) — the
        // rule must judge the pure RSS curve (flat here), not a spliced one.
        var footprint = (0...30).map { 400.0 + Double($0) * 20 }
        footprint[15] = 0
        #expect(DetectionRules.footprintLeakAnomaly(
            history: counterSamples(minutes: 30, footprintMB: footprint, rssMB: (0...30).map { _ in 600 })
        ) == nil)
    }

    @Test("rejects sawtooth growth (caches, GC) as non-monotonic")
    func rejectsSawtooth() {
        let footprint = (0...30).map { 300.0 + Double($0 % 2 == 0 ? $0 * 40 : 0) }
        #expect(DetectionRules.footprintLeakAnomaly(
            history: counterSamples(minutes: 30, footprintMB: footprint)
        ) == nil)
    }

    @Test("deviation annotation quotes the selected baseline when provided")
    func annotatesDeviation() {
        let footprint = (0...30).map { 300.0 + Double($0) * 25 }
        let anomaly = DetectionRules.footprintLeakAnomaly(
            history: counterSamples(minutes: 30, footprintMB: footprint),
            baseline: baseline(median: 310, mad: 20)
        )
        #expect((anomaly?.baselineDeviation ?? 0) > 8)
    }
}

@Suite("memory ceiling on the primary (footprint-first) memory number")
struct MemoryCeilingTests {
    @Test("fires on footprint even when RSS looks modest")
    func footprintPrimary() {
        let sample = ProcessSample(
            identity: identity(), timestamp: .now, cpuTimeSeconds: 1,
            residentBytes: 1024 * 1024 * 1024, uptimeSeconds: 60,
            physFootprintBytes: 17 * 1024 * 1024 * 1024
        )
        #expect(DetectionRules.rssCeilingAnomaly(sample: sample)?.kind == .rssCeiling)
    }

    @Test("falls back to RSS when footprint is unknown (0)")
    func rssFallback() {
        let sample = ProcessSample(
            identity: identity(), timestamp: .now, cpuTimeSeconds: 1,
            residentBytes: 17 * 1024 * 1024 * 1024, uptimeSeconds: 60
        )
        #expect(DetectionRules.rssCeilingAnomaly(sample: sample)?.kind == .rssCeiling)
    }
}

@Suite("knowledge map")
struct KnowledgeMapTests {
    @Test("shipped map loads and contains the founding-incident daemons")
    func shippedMapLoads() throws {
        let map = try KnowledgeMap.shipped()
        #expect(map.count >= 40)
        #expect(map.entry(forProcessName: "dasd")?.safetyTier == 1)
        #expect(map.entry(forProcessName: "kernel_task")?.safetyTier == 3)
        #expect(map.entry(forProcessName: "dasd")?.causallyLinked.contains("appstoreagent") == true)
    }

    @Test("map-only card for an unknown process is tier 3 with no action")
    func unknownProcessIsConservative() throws {
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        _ = engine // engine's async path exercised in integration; here we test the deterministic card
        let anomaly = Anomaly(kind: .sustainedCPU, identity: ProcessIdentity(pid: 999, startAbsTime: 1, executableName: "totally_unknown_proc"), windowSeconds: 1800, magnitudeCurve: [90], baselineValue: nil, detectedAt: .now)
        let card = JudgmentEngine.mapOnlyCard(anomaly: anomaly, entry: nil, baselineSentence: "No baseline yet.")
        #expect(card.actionSafetyTier == 3)
        #expect(card.causallyLinkedProcesses.isEmpty)
    }
}

@Suite("chronic CPU — the baseline-poisoning catch")
struct ChronicCPUTests {
    @Test("flags a process whose robust median CPU is itself pathological (poisoned baseline, e.g. appstoreagent ~62%)")
    func flagsChronicRunaway() {
        let robust = RobustStats(median: 62, mad: 5, count: 40)
        let anomaly = DetectionRules.chronicCPUAnomaly(
            robust: robust,
            sample: sample(cpuTime: 0, uptime: 3600, name: "appstoreagent")
        )
        #expect(anomaly?.kind == .sustainedCPU)
        #expect(anomaly?.identity.executableName == "appstoreagent")
    }

    @Test("does not flag a process whose typical CPU is below the chronic floor")
    func ignoresNormalLoad() {
        let robust = RobustStats(median: 12, mad: 3, count: 40)
        #expect(DetectionRules.chronicCPUAnomaly(robust: robust, sample: sample(cpuTime: 0, uptime: 3600)) == nil)
    }

    @Test("never fires on a cold process with no robust stats yet")
    func ignoresColdProcess() {
        #expect(DetectionRules.chronicCPUAnomaly(robust: nil, sample: sample(cpuTime: 0, uptime: 3600)) == nil)
    }
}
