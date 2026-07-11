import Testing
import Foundation
@testable import AnomalousCore

// JournalAnalytics turns the local incident journal into the dashboard digest:
// range windowing, kind/resolution tallies, per-day bucketing, per-process
// grouping, and the self-resolved rate. Deterministic via injected now + a
// fixed UTC calendar.

private let now = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15 14:13:20Z

private var utcCalendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func je(
    _ name: String,
    bundleID: String? = nil,
    kind: Anomaly.Kind = .sustainedCPU,
    resolution: AnomalyResolution = .recovered,
    agoHours: Double,
    activeSeconds: TimeInterval = 120
) -> JournalEntry {
    let detected = now.addingTimeInterval(-agoHours * 3600)
    return JournalEntry(
        processName: name, bundleID: bundleID, kind: kind.rawValue,
        summary: "\(name) summary", action: "Quit it.",
        safetyTier: 1, judgedByModel: false,
        detectedAt: detected, resolvedAt: detected.addingTimeInterval(activeSeconds),
        resolution: resolution
    )
}

private func digest(_ entries: [JournalEntry], _ range: HistoryRange = .unlimited) -> AnomalyDigest {
    JournalAnalytics.digest(from: entries, range: range, now: now, calendar: utcCalendar)
}

@Suite("journal analytics — the dashboard digest")
struct JournalAnalyticsTests {
    @Test("empty journal yields an all-zero digest")
    func emptyDigest() {
        let d = digest([])
        #expect(d.total == 0)
        #expect(d.distinctProcesses == 0)
        #expect(d.selfResolvedRate == 0)
        #expect(d.byKind.isEmpty && d.byType.isEmpty && d.byResolution.isEmpty && d.perDay.isEmpty && d.processes.isEmpty)
        #expect(d.mostCommonType == nil)
    }

    @Test("range windowing drops incidents outside the lookback")
    func rangeWindowing() {
        let entries = [
            je("a", agoHours: 2),      // within day
            je("b", agoHours: 30),     // within week, outside day
            je("c", agoHours: 24 * 10) // within month, outside week
        ]
        #expect(digest(entries, .day).total == 1)
        #expect(digest(entries, .week).total == 2)
        #expect(digest(entries, .month).total == 3)
        #expect(digest(entries, .unlimited).total == 3)
    }

    @Test("byKind is raw and most-common-first")
    func byKind() {
        let entries =
            (0..<5).map { je("p\($0)", kind: .sustainedCPU, agoHours: 1) } +
            (0..<2).map { je("q\($0)", kind: .gpuSaturation, agoHours: 1) } +
            [je("r", kind: .memoryLeakFootprint, agoHours: 1)]
        let d = digest(entries)
        #expect(d.byKind.map(\.kind) == ["sustained_cpu", "gpu.saturation", "memory.leak_footprint"])
        #expect(d.byKind.first?.count == 5)
    }

    @Test("byType folds raw kinds sharing a plain label into one summed bar")
    func byTypeAggregation() {
        // sustained_cpu (3) + cputime_ratio (2) both display as "High CPU" → 5.
        let entries =
            (0..<3).map { je("p\($0)", kind: .sustainedCPU, agoHours: 1) } +
            (0..<2).map { je("q\($0)", kind: .cpuTimeRatio, agoHours: 1) } +
            [je("r", kind: .gpuSaturation, agoHours: 1)]
        let d = digest(entries)
        #expect(d.byKind.count == 3)                        // raw keeps them separate
        #expect(d.byType.map(\.label) == ["High CPU", "GPU running hot"])
        #expect(d.byType.first?.count == 5)                 // 3 + 2 folded
        #expect(d.mostCommonType?.label == "High CPU")
        // the representative kind colours to one of the CPU kinds
        #expect(["sustained_cpu", "cputime_ratio"].contains(d.byType.first!.representativeKind))
    }

    @Test("byResolution counts in stable enum order, zero-count omitted")
    func byResolution() {
        let entries = [
            je("a", resolution: .recovered, agoHours: 1),
            je("b", resolution: .recovered, agoHours: 1),
            je("c", resolution: .actioned, agoHours: 1),
            je("d", resolution: .dismissed, agoHours: 1),
        ]
        let d = digest(entries)
        // enum order: recovered, ended, dismissed, actioned, acknowledged, snoozed
        #expect(d.byResolution.map(\.resolution) == [.recovered, .dismissed, .actioned])
        #expect(d.byResolution.first { $0.resolution == .recovered }?.count == 2)
    }

    @Test("self-resolved rate counts recovered + ended only")
    func selfResolvedRate() {
        let entries = [
            je("a", resolution: .recovered, agoHours: 1),
            je("b", resolution: .ended, agoHours: 1),
            je("c", resolution: .actioned, agoHours: 1),
            je("d", resolution: .dismissed, agoHours: 1),
        ]
        #expect(digest(entries).selfResolvedRate == 0.5)
    }

    @Test("perDay buckets by calendar day, ascending and sparse")
    func perDay() {
        let entries = [
            je("a", agoHours: 2),   // today
            je("b", agoHours: 5),   // today
            je("c", agoHours: 30),  // yesterday (UTC)
        ]
        let d = digest(entries)
        #expect(d.perDay.count == 2)
        #expect(d.perDay.map(\.count) == [1, 2])          // ascending by day: yesterday(1), today(2)
        #expect(d.perDay[0].day < d.perDay[1].day)
    }

    @Test("processes group by identity, sorted by count then recency")
    func processGrouping() {
        let entries =
            (0..<3).map { je("appstoreagent", kind: .sustainedCPU, agoHours: Double($0 + 1)) } +
            (0..<2).map { je("WindowServer", kind: .gpuSaturation, agoHours: Double($0 + 1)) } +
            [je("Dropbox", bundleID: "com.getdropbox.dropbox", agoHours: 1)]
        let d = digest(entries)
        #expect(d.distinctProcesses == 3)
        #expect(d.processes.map(\.displayName) == ["appstoreagent", "WindowServer", "Dropbox"])
        let top = d.processes[0]
        #expect(top.count == 3)
        #expect(top.episodes.first!.detectedAt > top.episodes.last!.detectedAt) // newest-first
        #expect(top.firstDetectedAt == top.episodes.last!.detectedAt)
    }

    @Test("a bundled app and a same-named daemon don't merge")
    func identityDoesNotCrossMatch() {
        let entries = [
            je("Helper", bundleID: "com.acme.App", agoHours: 1),
            je("Helper", bundleID: nil, agoHours: 1),
        ]
        #expect(digest(entries).distinctProcesses == 2)
    }

    @Test("per-process kinds are distinct, most-frequent first")
    func processKinds() {
        let entries =
            (0..<3).map { je("p", kind: .sustainedCPU, agoHours: Double($0 + 1)) } +
            [je("p", kind: .gpuSaturation, agoHours: 5)]
        let proc = digest(entries).processes.first!
        #expect(proc.kinds == ["sustained_cpu", "gpu.saturation"])
        #expect(proc.selfResolvedRate == 1.0)   // all recovered
    }

    @Test("HistoryRange windows are day/week/month/unlimited")
    func rangeWindows() {
        #expect(HistoryRange.day.window == 86_400.0)
        #expect(HistoryRange.week.window == 604_800.0)
        #expect(HistoryRange.month.window == 2_592_000.0)
        #expect(HistoryRange.unlimited.window == nil)
        #expect(HistoryRange.allCases.map(\.label) == ["Day", "Week", "Month", "Unlimited"])
    }
}

// A JournalEntry with fully-explicit detected/resolved dates — for the ordering,
// boundary, and timezone contracts where the je() helper's coupling hides bugs.
private func raw(
    _ name: String,
    bundleID: String? = nil,
    kind: Anomaly.Kind = .sustainedCPU,
    resolution: AnomalyResolution = .recovered,
    detected: Date,
    resolved: Date
) -> JournalEntry {
    JournalEntry(
        processName: name, bundleID: bundleID, kind: kind.rawValue,
        summary: "s", action: "a", safetyTier: 1, judgedByModel: false,
        detectedAt: detected, resolvedAt: resolved, resolution: resolution
    )
}

/// Deterministic-ordering, identity, boundary, and timezone contracts the UI
/// depends on — none of which the primary suite exercises (the pre-sort source
/// is a Dictionary, so these tie-breaks are the ONLY thing making output stable).
@Suite("journal analytics — load-bearing contracts")
struct JournalAnalyticsContractTests {
    @Test("byKind ties break alphabetically by rawValue")
    func byKindTieBreak() {
        let entries = [
            je("a", kind: .sustainedCPU, agoHours: 1),
            je("b", kind: .sustainedCPU, agoHours: 1),
            je("c", kind: .gpuSaturation, agoHours: 1),
            je("d", kind: .gpuSaturation, agoHours: 1),
            je("e", kind: .memoryLeakFootprint, agoHours: 1),
        ]
        // "gpu.saturation" < "memory.leak_footprint" < "sustained_cpu"; the two
        // tied-at-2 sort alphabetically, so gpu comes before sustained.
        #expect(digest(entries).byKind.map(\.kind) == ["gpu.saturation", "sustained_cpu", "memory.leak_footprint"])
    }

    @Test("equal-count processes break ties by most-recent resolution")
    func processTieBreakByRecency() {
        let d = JournalAnalyticsTestsClock.now
        let a = raw("A", detected: d.addingTimeInterval(-5 * 3600), resolved: d.addingTimeInterval(-5 * 3600 + 60))
        let b = raw("B", detected: d.addingTimeInterval(-2 * 3600), resolved: d.addingTimeInterval(-1 * 3600))
        let out = JournalAnalytics.digest(from: [a, b], range: .unlimited, now: d, calendar: utc)
        #expect(out.processes.map(\.displayName) == ["B", "A"])   // B resolved more recently
    }

    @Test("empty-string bundleID is treated as no bundle")
    func emptyBundleIsNil() {
        let d = JournalAnalyticsTestsClock.now
        // "" and nil both group by name → merge.
        let merge = JournalAnalytics.digest(
            from: [raw("Helper", bundleID: "", detected: d, resolved: d), raw("Helper", bundleID: nil, detected: d, resolved: d)],
            range: .unlimited, now: d, calendar: utc)
        #expect(merge.distinctProcesses == 1)
        // "" (name-based) and a real id (bundle-based) do NOT merge.
        let split = JournalAnalytics.digest(
            from: [raw("Helper", bundleID: "", detected: d, resolved: d), raw("Helper", bundleID: "com.acme.App", detected: d, resolved: d)],
            range: .unlimited, now: d, calendar: utc)
        #expect(split.distinctProcesses == 2)
    }

    @Test("window boundary is inclusive on resolvedAt")
    func windowBoundaryInclusive() {
        let d = JournalAnalyticsTestsClock.now
        let onBoundary = raw("a", detected: d.addingTimeInterval(-90_000), resolved: d.addingTimeInterval(-86_400)) // exactly now-24h
        let justOutside = raw("b", detected: d.addingTimeInterval(-90_000), resolved: d.addingTimeInterval(-86_401)) // 1s earlier
        let out = JournalAnalytics.digest(from: [onBoundary, justOutside], range: .day, now: d, calendar: utc)
        #expect(out.total == 1)
        #expect(out.processes.first?.displayName == "a")
    }

    @Test("an incident detected before the window but resolved inside it is included; firstDetectedAt keeps its true (out-of-range) time")
    func detectedBeforeWindow() {
        let d = JournalAnalyticsTestsClock.now
        let e = raw("slowburn", detected: d.addingTimeInterval(-10 * 86_400), resolved: d.addingTimeInterval(-3600))
        let out = JournalAnalytics.digest(from: [e], range: .day, now: d, calendar: utc)
        #expect(out.total == 1)   // scoped on resolvedAt, which is inside the day
        #expect(out.processes.first?.firstDetectedAt == d.addingTimeInterval(-10 * 86_400))
    }

    @Test("firstDetectedAt is the true minimum, independent of episode resolution order")
    func firstDetectedAtIsTrueMin() {
        let d = JournalAnalyticsTestsClock.now
        // A detected earlier but resolves fast; B detected later but resolves last.
        let a = raw("p", detected: d.addingTimeInterval(-3 * 3600), resolved: d.addingTimeInterval(-3 * 3600 + 10))
        let b = raw("p", detected: d.addingTimeInterval(-2 * 3600), resolved: d.addingTimeInterval(-1))
        let proc = JournalAnalytics.digest(from: [a, b], range: .unlimited, now: d, calendar: utc).processes.first!
        #expect(proc.episodes.first?.processName == "p")            // newest-resolved is B
        #expect(proc.firstDetectedAt == d.addingTimeInterval(-3 * 3600)) // still A's detection
    }

    @Test("byResolution spans all six kinds in stable enum order")
    func byResolutionFullOrder() {
        let d = JournalAnalyticsTestsClock.now
        let all: [AnomalyResolution] = [.snoozed, .acknowledged, .actioned, .dismissed, .ended, .recovered]
        let entries = all.map { raw("p-\($0.rawValue)", resolution: $0, detected: d, resolved: d) }
        let out = JournalAnalytics.digest(from: entries, range: .unlimited, now: d, calendar: utc)
        #expect(out.byResolution.map(\.resolution) == [.recovered, .ended, .dismissed, .actioned, .acknowledged, .snoozed])
    }

    @Test("perDay follows the injected calendar's timezone, not UTC")
    func perDayTimezone() {
        let f = ISO8601DateFormatter()
        // Both fall on 2025-06-15 in America/Los_Angeles, but straddle UTC midnight.
        let e1 = raw("p", detected: f.date(from: "2025-06-15T23:30:00Z")!, resolved: f.date(from: "2025-06-15T23:30:00Z")!)
        let e2 = raw("q", detected: f.date(from: "2025-06-16T02:30:00Z")!, resolved: f.date(from: "2025-06-16T02:30:00Z")!)
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = f.date(from: "2025-06-17T00:00:00Z")!
        #expect(JournalAnalytics.digest(from: [e1, e2], range: .unlimited, now: now, calendar: la).perDay.count == 1)
        var u = Calendar(identifier: .gregorian); u.timeZone = TimeZone(identifier: "UTC")!
        #expect(JournalAnalytics.digest(from: [e1, e2], range: .unlimited, now: now, calendar: u).perDay.count == 2)
    }

    @Test("many incidents on one calendar day collapse to a single bucket")
    func perDaySameDay() {
        let entries = (0..<6).map { je("p\($0)", agoHours: Double($0)) } // 0..5h ago — all today (now is 14:13Z)
        let out = digest(entries)
        #expect(out.perDay.count == 1)
        #expect(out.perDay.first?.count == 6)
    }

    @Test("selfResolvedRate: only recovered + ended count; snoozed/acknowledged/actioned/dismissed do not")
    func selfResolvedExtremes() {
        let d = JournalAnalyticsTestsClock.now
        let none = [AnomalyResolution.dismissed, .actioned, .acknowledged, .snoozed].map { raw("p", resolution: $0, detected: d, resolved: d) }
        #expect(JournalAnalytics.digest(from: none, range: .unlimited, now: d, calendar: utc).selfResolvedRate == 0.0)
    }
}

/// Shared fixed clock + UTC calendar for the contract suite.
private enum JournalAnalyticsTestsClock {
    static let now = Date(timeIntervalSince1970: 1_750_000_000)
}
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
