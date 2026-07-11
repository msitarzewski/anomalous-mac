import Testing
import Foundation
@testable import AnomalousCore

// RecurrenceFinder folds the local journal into the "First flagged … · returned
// N×" card footer: a process that genuinely cleared (recovered / exited /
// handled) and re-tripped reads as an ongoing saga, not a fresh one-minute
// blip. These tests pin identity matching, the resolution allow-list, the
// 24h window, the earliest-start rollup, and the today-scoping — all with an
// injected `now` and a fixed UTC calendar so nothing depends on wall-clock.

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
    agoHours: Double
) -> JournalEntry {
    let detected = now.addingTimeInterval(-agoHours * 3600)
    return JournalEntry(
        processName: name, bundleID: bundleID, kind: kind.rawValue,
        summary: "\(name) summary", action: "Quit it.",
        safetyTier: 1, judgedByModel: false,
        detectedAt: detected, resolvedAt: detected.addingTimeInterval(120),
        resolution: resolution
    )
}

private func summary(
    _ entries: [JournalEntry],
    name: String = "appstoreagent",
    bundleID: String? = nil,
    kind: Anomaly.Kind = .sustainedCPU
) -> RecurrenceSummary? {
    RecurrenceFinder.summary(
        kind: kind.rawValue, bundleID: bundleID, processName: name,
        detectedAt: now, in: entries, now: now, calendar: utcCalendar
    )
}

@Suite("recurrence finder — journal-driven \"returned N×\"")
struct RecurrenceFinderTests {
    @Test("a genuine first flag has no recurrence")
    func firstFlagIsNil() {
        #expect(summary([]) == nil)
    }

    @Test("one prior recovered episode counts as returned once, saga starts at the prior")
    func onePriorEpisode() {
        let priorHoursAgo = 2.0
        let s = summary([je("appstoreagent", agoHours: priorHoursAgo)])
        #expect(s?.returnCount == 1)
        #expect(s?.firstFlaggedAt == now.addingTimeInterval(-priorHoursAgo * 3600))
    }

    @Test("multiple priors accumulate; firstFlaggedAt is the earliest")
    func multiplePriors() {
        let s = summary([
            je("appstoreagent", agoHours: 1),
            je("appstoreagent", agoHours: 3),
            je("appstoreagent", agoHours: 6),
        ])
        #expect(s?.returnCount == 3)
        #expect(s?.firstFlaggedAt == now.addingTimeInterval(-6 * 3600))
    }

    @Test("dismissed / acknowledged / snoozed do not count — only genuine resolutions")
    func onlyGenuineResolutionsCount() {
        #expect(summary([je("x", resolution: .dismissed, agoHours: 1)]) == nil)
        #expect(summary([je("x", resolution: .acknowledged, agoHours: 1)], name: "x") == nil)
        #expect(summary([je("x", resolution: .snoozed, agoHours: 1)], name: "x") == nil)
        // recovered / ended / actioned all count
        #expect(summary([je("x", resolution: .recovered, agoHours: 1)], name: "x")?.returnCount == 1)
        #expect(summary([je("x", resolution: .ended, agoHours: 1)], name: "x")?.returnCount == 1)
        #expect(summary([je("x", resolution: .actioned, agoHours: 1)], name: "x")?.returnCount == 1)
    }

    @Test("episodes older than the 24h window are ignored")
    func outsideWindowIgnored() {
        #expect(summary([je("appstoreagent", agoHours: 30)]) == nil)
        // one in-window + one out: only the in-window counts
        let s = summary([
            je("appstoreagent", agoHours: 5),
            je("appstoreagent", agoHours: 48),
        ])
        #expect(s?.returnCount == 1)
        #expect(s?.firstFlaggedAt == now.addingTimeInterval(-5 * 3600))
    }

    @Test("a different anomaly kind is a different problem, not a recurrence")
    func differentKindDoesNotMatch() {
        let leak = je("appstoreagent", kind: .memoryLeakFootprint, agoHours: 2)
        #expect(summary([leak], kind: .sustainedCPU) == nil)
    }

    @Test("bundled apps match on bundle id; a same-named helper doesn't cross-match")
    func bundleIdentityMatching() {
        let appPrior = je("MyApp", bundleID: "com.acme.MyApp", agoHours: 2)
        #expect(summary([appPrior], name: "MyApp", bundleID: "com.acme.MyApp")?.returnCount == 1)
        // a bundle-less helper named the same must not match the bundled app's history
        #expect(summary([appPrior], name: "MyApp", bundleID: nil) == nil)
    }

    @Test("bundle-less daemons match on process name only against other bundle-less entries")
    func bundlelessMatching() {
        let daemon = je("dasd", bundleID: nil, agoHours: 2)
        #expect(summary([daemon], name: "dasd", bundleID: nil)?.returnCount == 1)
        // a bundled entry that happens to share the name must not match a daemon
        let bundled = je("dasd", bundleID: "com.example.dasd", agoHours: 2)
        #expect(summary([bundled], name: "dasd", bundleID: nil) == nil)
    }

    @Test("scopedToToday is true only when the saga began the same calendar day as now")
    func todayScoping() {
        // 5h ago is the same UTC day (now is 14:13Z)
        #expect(summary([je("appstoreagent", agoHours: 5)])?.scopedToToday == true)
        // 20h ago crosses into the previous UTC day but is still within 24h
        let s = summary([je("appstoreagent", agoHours: 20)])
        #expect(s?.returnCount == 1)
        #expect(s?.scopedToToday == false)
    }
}
