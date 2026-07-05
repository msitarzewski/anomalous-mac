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
        let journal = AnomalyJournal(fileURL: tempURL())
        for i in 0..<(AnomalyJournal.maxEntries + 25) {
            await journal.record(entry("proc-\(i)"))
        }
        let all = await journal.recent(AnomalyJournal.maxEntries + 100)
        #expect(all.count == AnomalyJournal.maxEntries)
        // Newest first: the very last recorded is at the head; the oldest 25
        // (proc-0…proc-24) were dropped.
        #expect(all.first?.processName == "proc-\(AnomalyJournal.maxEntries + 24)")
        #expect(all.last?.processName == "proc-25")
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
