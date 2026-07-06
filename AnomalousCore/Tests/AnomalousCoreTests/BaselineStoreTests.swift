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

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("a v1 baselines.json (pre-robust) loads losslessly — versioned decode")
    func v1FileDecodes() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exactly what a pre-Phase-2 build wrote: schemaVersion 1, no
        // `robust` key. Flags, EWMAs, and cached cards must all survive.
        let v1 = """
        {"schemaVersion":1,
         "baselines":{"dasd":{"ewmaCPUPercent":0.1,"ewmaRSSMB":35,"sampleCount":400,
                              "firstSeen":700000000,"lastSeen":773000000}},
         "flagged":[{"identity":{"pid":100,"startAbsTime":555,"executableName":"dasd"},
                     "kind":"cputime_ratio","flaggedAt":\(Date.now.timeIntervalSinceReferenceDate)}],
         "diagnoses":{}}
        """
        try Data(v1.utf8).write(to: url)

        let store = BaselineStore(fileURL: url)
        await store.loadIfNeeded()
        #expect(await store.isFlagged(dasd))
        #expect(await store.baseline(forKey: "dasd")?.sampleCount == 400)
        #expect(await store.robustStats(forKey: "dasd", metric: .cpuPercent) == nil)   // warms fresh
    }

    @Test("recordTick accumulates robust stats and selects seasonal once warm")
    func recordTickSelection() async {
        let store = BaselineStore(fileURL: tempFile())
        await store.loadIfNeeded()
        // Fixed date → fixed bucket, so every tick lands in ONE bucket.
        let start = utc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))!

        var lastJudgment: BaselineStore.TickJudgment?
        for tick in 0..<6 {
            lastJudgment = await store.recordTick(
                key: "backupd",
                at: start.addingTimeInterval(Double(tick) * 90),
                observations: [.cpuPercent: 3, .diskBytesPerSecond: 90 * 1_048_576],
                calendar: utc
            )
        }
        // Selection happens BEFORE recording: after 6 ticks the bucket held 5
        // observations at selection time — seasonal judgment is now live.
        #expect(lastJudgment?.baselines[.diskBytesPerSecond]?.isSeasonal == true)
        #expect(lastJudgment?.baselines[.diskBytesPerSecond]?.stats.median == 90.0 * 1_048_576)

        let global = await store.robustStats(forKey: "backupd", metric: .diskBytesPerSecond)
        #expect(global?.count == 6)
        #expect(global?.median == 90.0 * 1_048_576)
        // The EWMA path was fed through the same call.
        #expect(await store.baseline(forKey: "backupd") != nil)
    }

    @Test("feedBaselines: false freezes the baseline — a flagged runaway can't become 'normal'")
    func flaggedTicksDoNotTeach() async {
        let store = BaselineStore(fileURL: tempFile())
        await store.loadIfNeeded()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        for tick in 0..<10 {
            _ = await store.recordTick(key: "mysqld", at: date.addingTimeInterval(Double(tick) * 90), observations: [.cpuPercent: 2, .wakeupsPerSecond: 5])
        }
        // The runaway episode: readings still SELECT a baseline (judgment
        // continues) but record nothing.
        for tick in 10..<20 {
            let judgment = await store.recordTick(
                key: "mysqld",
                at: date.addingTimeInterval(Double(tick) * 90),
                observations: [.cpuPercent: 150, .wakeupsPerSecond: 1400],
                feedBaselines: false
            )
            #expect(judgment.baselines[.wakeupsPerSecond]?.stats.median == 5)
        }
        let stats = await store.robustStats(forKey: "mysqld", metric: .wakeupsPerSecond)
        #expect(stats?.count == 10)      // nothing recorded during the episode
        #expect(stats?.median == 5)
    }

    @Test("robust + seasonal state round-trips through save/load")
    func robustPersistence() async {
        let url = tempFile()
        let store = BaselineStore(fileURL: url)
        await store.loadIfNeeded()
        let start = utc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))!
        for tick in 0..<8 {
            _ = await store.recordTick(
                key: "dasd",
                at: start.addingTimeInterval(Double(tick) * 90),
                observations: [.cpuPercent: 0.1, .memoryMB: 35],
                calendar: utc
            )
        }
        await store.save()

        let reloaded = BaselineStore(fileURL: url)
        await reloaded.loadIfNeeded()
        let stats = await reloaded.robustStats(forKey: "dasd", metric: .cpuPercent)
        #expect(stats?.count == 8)
        #expect(stats?.median == 0.1)
        #expect(await reloaded.seasonalStats(forKey: "dasd", metric: .cpuPercent, bucket: "wd-2")?.count == 8)
    }

    @Test("robust state for a lineage not seen in 30 days decays at load")
    func robustTTLPrune() async {
        let url = tempFile()
        let store = BaselineStore(fileURL: url)
        await store.loadIfNeeded()
        _ = await store.recordTick(key: "ghost", at: .now.addingTimeInterval(-40 * 86_400), observations: [.cpuPercent: 1])
        _ = await store.recordTick(key: "living", at: .now, observations: [.cpuPercent: 1])
        await store.save()

        let reloaded = BaselineStore(fileURL: url)
        await reloaded.loadIfNeeded()
        #expect(await reloaded.robustStats(forKey: "ghost", metric: .cpuPercent) == nil)
        #expect(await reloaded.robustStats(forKey: "living", metric: .cpuPercent) != nil)
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
