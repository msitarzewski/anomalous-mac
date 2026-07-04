import Testing
import Foundation
@testable import AnomalousCore

@Suite("baseline store — memory across launches")
struct BaselineStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "anomalous-tests-\(UUID().uuidString)/baselines.json")
    }

    private var dasd: ProcessIdentity {
        ProcessIdentity(pid: 100, startAbsTime: 555, executableName: "dasd")
    }

    @Test("flagged instances survive a save/load round trip")
    func flagPersistence() async {
        let url = tempFile()
        let store = BaselineStore(fileURL: url)
        await store.loadIfNeeded()
        await store.markFlagged(dasd, kind: .cpuTimeRatio)
        await store.save()

        let reloaded = BaselineStore(fileURL: url)
        await reloaded.loadIfNeeded()
        #expect(await reloaded.isFlagged(dasd))
        // Same executable, NEW process instance (restarted) — not suppressed.
        let respawned = ProcessIdentity(pid: 101, startAbsTime: 999, executableName: "dasd")
        #expect(await reloaded.isFlagged(respawned) == false)
    }

    @Test("EWMA baseline converges toward sustained readings")
    func ewmaConverges() async {
        let store = BaselineStore(fileURL: tempFile())
        await store.loadIfNeeded()
        for _ in 0..<200 { await store.record(key: "dasd", cpuPercent: 0.1, rssMB: 35) }
        let calm = await store.baseline(forKey: "dasd")
        #expect(calm != nil && abs(calm!.ewmaCPUPercent - 0.1) < 0.05)

        for _ in 0..<200 { await store.record(key: "dasd", cpuPercent: 150, rssMB: 34_000) }
        let hot = await store.baseline(forKey: "dasd")
        #expect(hot!.ewmaCPUPercent > 100)
        #expect(hot!.sampleCount == 400)
    }

    @Test("baseline sentence is a complete diagnosis input")
    func sentenceShape() async {
        let store = BaselineStore(fileURL: tempFile())
        await store.loadIfNeeded()
        await store.record(key: "dasd", cpuPercent: 0.1, rssMB: 35)
        let sentence = await store.baseline(forKey: "dasd")!.sentence
        #expect(sentence.contains("CPU"))
        #expect(sentence.contains("MB"))
    }

    @Test("stale flagged records are pruned at load (re-surface old runaways)")
    func flaggedTTL() async throws {
        let url = tempFile()
        // Hand-write a snapshot with an ancient flag.
        let old = BaselineStore.FlaggedRecord(identity: dasd, kind: "cputime_ratio", flaggedAt: .now.addingTimeInterval(-8 * 86_400))
        let json = try JSONEncoder().encode(["schemaVersion": 1] as [String: Int])
        _ = json // structure written via store round-trip instead:
        let store = BaselineStore(fileURL: url)
        await store.loadIfNeeded()
        await store.markFlagged(dasd, kind: .cpuTimeRatio)
        await store.save()
        // Rewrite file with backdated flaggedAt.
        var raw = try String(contentsOf: url, encoding: .utf8)
        let recent = try #require(raw.range(of: #""flaggedAt":[0-9.-]+"#, options: .regularExpression))
        raw.replaceSubrange(recent, with: "\"flaggedAt\":\(old.flaggedAt.timeIntervalSinceReferenceDate)")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let reloaded = BaselineStore(fileURL: url)
        await reloaded.loadIfNeeded()
        #expect(await reloaded.isFlagged(dasd) == false)
    }
}
