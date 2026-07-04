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
