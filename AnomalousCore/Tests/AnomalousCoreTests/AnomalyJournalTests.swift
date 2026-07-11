import Testing
import Foundation
@testable import AnomalousCore

// The journal is the user's private, local-only incident history. These tests
// exercise ordering, persistence round-trips, the bound, slicing, and clear —
// all against a throwaway temp file so nothing touches real user data.

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "anomalous-journal-tests-\(UUID().uuidString)/journal.json")
}

private func entry(_ name: String, detectedAt: Date = .now, resolvedAt: Date = .now, resolution: AnomalyResolution = .ended) -> JournalEntry {
    JournalEntry(
        processName: name, bundleID: nil, kind: Anomaly.Kind.appHung.rawValue,
        summary: "\(name) summary", action: "Force quit and relaunch it.",
        safetyTier: 2, judgedByModel: false,
        detectedAt: detectedAt, resolvedAt: resolvedAt, resolution: resolution
    )
}

@Suite("anomaly journal — local incident history")
struct AnomalyJournalTests {
    @Test("record prepends newest-first")
    func recordPrependsNewestFirst() async {
        let journal = AnomalyJournal(fileURL: tempURL())
        await journal.record(entry("first"))
        await journal.record(entry("second"))
        await journal.record(entry("third"))
        let recent = await journal.recent()
        #expect(recent.map(\.processName) == ["third", "second", "first"])
    }

    @Test("save then a fresh instance round-trips via the file")
    func persistsAcrossInstances() async {
        let url = tempURL()
        let writer = AnomalyJournal(fileURL: url)
        await writer.record(entry("persisted"))   // record() saves internally
        await writer.save()

        let reader = AnomalyJournal(fileURL: url)
        await reader.loadIfNeeded()
        let recent = await reader.recent()
        #expect(recent.count == 1)
        #expect(recent.first?.processName == "persisted")
    }

    @Test("the maxEntries cap drops the oldest")
    func capDropsOldest() async {
        let cap = 40
        let journal = AnomalyJournal(fileURL: tempURL(), maxEntries: cap)
        for i in 0..<(cap + 25) {
            await journal.record(entry("proc-\(i)"))
        }
        let all = await journal.recent(cap + 100)
        #expect(all.count == cap)
        // Newest first: the very last recorded is at the head; the oldest 25
        // (proc-0…proc-24) were dropped.
        #expect(all.first?.processName == "proc-\(cap + 24)")
        #expect(all.last?.processName == "proc-25")
    }

    @Test("default retention is 1000")
    func defaultRetention() {
        #expect(AnomalyJournal.defaultMaxEntries == 1000)
    }

    @Test("lowering the cap trims immediately")
    func setMaxEntriesTrims() async {
        let journal = AnomalyJournal(fileURL: tempURL(), maxEntries: 100)
        for i in 0..<30 { await journal.record(entry("p\(i)")) }
        await journal.setMaxEntries(10)
        let all = await journal.recent(100)
        #expect(all.count == 10)
        #expect(all.first?.processName == "p29")   // newest kept
        #expect(all.last?.processName == "p20")     // oldest 20 trimmed
    }

    @Test("raising the cap keeps existing entries")
    func raisingCapKeepsEntries() async {
        let journal = AnomalyJournal(fileURL: tempURL(), maxEntries: 5)
        for i in 0..<5 { await journal.record(entry("p\(i)")) }
        await journal.setMaxEntries(50)
        #expect(await journal.recent(100).count == 5)
    }

    @Test("a single corrupt entry is skipped, the rest of the history survives")
    func lossyDecodeSkipsBadEntries() async throws {
        let url = tempURL()
        let writer = AnomalyJournal(fileURL: url)
        await writer.record(entry("good-old"))
        await writer.record(entry("good-new"))   // newest, index 0
        await writer.save()

        // Corrupt the newest entry by deleting its required processName.
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var entries = obj["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "processName")
        obj["entries"] = entries
        try JSONSerialization.data(withJSONObject: obj).write(to: url)

        let reader = AnomalyJournal(fileURL: url)
        await reader.loadIfNeeded()
        let recent = await reader.recent()
        #expect(recent.count == 1)                    // the intact one survived
        #expect(recent.first?.processName == "good-old")
    }

    @Test("load enforces the retention cap (a smaller cap trims on load)")
    func loadEnforcesCap() async {
        let url = tempURL()
        let writer = AnomalyJournal(fileURL: url, maxEntries: 100)
        for i in 0..<50 { await writer.record(entry("p\(i)")) }
        await writer.save()

        let reader = AnomalyJournal(fileURL: url, maxEntries: 10)
        await reader.loadIfNeeded()
        #expect(await reader.recent(1000).count == 10)
        #expect(await reader.recent().first?.processName == "p49")   // newest kept
    }

    @Test("the saved journal file is owner-only (0600)")
    func journalFileIsPrivate() async throws {
        let url = tempURL()
        let journal = AnomalyJournal(fileURL: url)
        await journal.record(entry("private"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        #expect(perms.int16Value == 0o600)
    }

    @Test("recent(limit) slices from the newest")
    func recentSlices() async {
        let journal = AnomalyJournal(fileURL: tempURL())
        for i in 0..<10 { await journal.record(entry("p\(i)")) }
        let three = await journal.recent(3)
        #expect(three.count == 3)
        #expect(three.map(\.processName) == ["p9", "p8", "p7"])
    }

    @Test("clear empties and persists the emptiness")
    func clearEmptiesAndPersists() async {
        let url = tempURL()
        let journal = AnomalyJournal(fileURL: url)
        await journal.record(entry("gone"))
        await journal.clear()
        #expect(await journal.recent().isEmpty)

        let reader = AnomalyJournal(fileURL: url)
        await reader.loadIfNeeded()
        #expect(await reader.recent().isEmpty)
    }
}

@Suite("journal entry + resolution semantics")
struct JournalEntryTests {
    @Test("duration is resolvedAt minus detectedAt")
    func durationSpansTheIncident() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let e = entry("slow", detectedAt: start, resolvedAt: start.addingTimeInterval(90))
        #expect(e.duration == 90)
    }

    @Test("duration never goes negative")
    func durationClampsToZero() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let e = entry("clockskew", detectedAt: start, resolvedAt: start.addingTimeInterval(-30))
        #expect(e.duration == 0)
    }

    @Test("resolution labels are the user-facing strings")
    func resolutionLabels() {
        #expect(AnomalyResolution.recovered.label == "Recovered")
        #expect(AnomalyResolution.ended.label == "Process ended")
        #expect(AnomalyResolution.dismissed.label == "Dismissed")
        #expect(AnomalyResolution.actioned.label == "Handled")
    }
}
