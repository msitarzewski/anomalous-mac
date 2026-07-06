import Foundation
import Testing
@testable import AnomalousCore

// Phase 4: the acknowledgment envelope. The re-alert matrix here IS the
// anti-mute guarantee — provable, not aspirational (phase-4 acceptance).

@Suite("acknowledgment envelope — re-alert decision (pure)")
struct ReAlertDecisionTests {
    /// Acked at 150 (% CPU) with the default background margin 1.5.
    private let acked = AcknowledgmentRecord(
        acknowledgedMagnitude: 150,
        envelopeMultiplier: 1.5,
        ackedAt: Date(timeIntervalSince1970: 1_000),
        processStartAbsTime: 42
    )

    @Test("acked at 150 → returns at 400 → re-alerts (materially worse)")
    func materiallyWorseRealerts() {
        let decision = AcknowledgmentStore.evaluate(
            record: acked, currentMagnitude: 400, processStartAbsTime: 42
        )
        #expect(decision == .realert(.materiallyWorse))
    }

    @Test("acked at 150 → returns at 150 → silent (within envelope)")
    func sameMagnitudeSuppresses() {
        let decision = AcknowledgmentStore.evaluate(
            record: acked, currentMagnitude: 150, processStartAbsTime: 42
        )
        #expect(decision == .suppress)
    }

    @Test("exactly at the envelope boundary stays suppressed; just past it re-alerts")
    func boundaryIsExclusive() {
        // 150 × 1.5 = 225: the envelope is "this much is fine".
        #expect(AcknowledgmentStore.evaluate(record: acked, currentMagnitude: 225, processStartAbsTime: 42) == .suppress)
        #expect(AcknowledgmentStore.evaluate(record: acked, currentMagnitude: 225.1, processStartAbsTime: 42) == .realert(.materiallyWorse))
    }

    @Test("envelope multiplier honored: 2.0 keeps 1.8× quiet, 1.5 re-alerts it")
    func multiplierHonored() {
        var wide = acked
        wide.envelopeMultiplier = 2.0
        // 1.8 × acked magnitude = 270.
        #expect(AcknowledgmentStore.evaluate(record: wide, currentMagnitude: 270, processStartAbsTime: 42) == .suppress)
        #expect(AcknowledgmentStore.evaluate(record: acked, currentMagnitude: 270, processStartAbsTime: 42) == .realert(.materiallyWorse))
    }

    @Test("new kind/dimension = different condition key = no record → not acknowledged")
    func newDimensionIsFreshCondition() {
        // The keying carries this leg: "gpu is fine" says nothing about memory.leak.
        let cpuKey = AcknowledgmentStore.conditionKey(processKey: "com.example.lmstudio", kind: "sustained_cpu", dimension: "cpu_percent")
        let leakKey = AcknowledgmentStore.conditionKey(processKey: "com.example.lmstudio", kind: "memory.leak_footprint", dimension: "memory_mb")
        #expect(cpuKey != leakKey)
        #expect(AcknowledgmentStore.evaluate(record: nil, currentMagnitude: 10, processStartAbsTime: 42) == .notAcknowledged)
    }

    @Test("process restart (new startAbsTime) → fresh evaluation (re-alerts)")
    func restartRealerts() {
        let decision = AcknowledgmentStore.evaluate(
            record: acked, currentMagnitude: 150, processStartAbsTime: 43
        )
        #expect(decision == .realert(.newInstance))
    }

    @Test("active snooze suppresses at the acked magnitude")
    func activeSnoozeSuppresses() {
        var snoozed = acked
        snoozed.snoozeUntil = Date(timeIntervalSince1970: 2_000)
        let decision = AcknowledgmentStore.evaluate(
            record: snoozed, currentMagnitude: 150, processStartAbsTime: 42,
            now: Date(timeIntervalSince1970: 1_500)
        )
        #expect(decision == .suppress)
    }

    @Test("snooze expiry while still active → re-surfaces")
    func snoozeExpiryResurfaces() {
        var snoozed = acked
        snoozed.snoozeUntil = Date(timeIntervalSince1970: 2_000)
        let decision = AcknowledgmentStore.evaluate(
            record: snoozed, currentMagnitude: 150, processStartAbsTime: 42,
            now: Date(timeIntervalSince1970: 2_000)
        )
        #expect(decision == .realert(.snoozeExpired))
    }

    @Test("anti-mute: materially worse breaks through an active snooze")
    func snoozeNeverMutesWorsening() {
        var snoozed = acked
        snoozed.snoozeUntil = Date(timeIntervalSince1970: 2_000)
        let decision = AcknowledgmentStore.evaluate(
            record: snoozed, currentMagnitude: 400, processStartAbsTime: 42,
            now: Date(timeIntervalSince1970: 1_500)
        )
        #expect(decision == .realert(.materiallyWorse))
    }

    @Test("anti-mute invariant: no acked state suppresses a condition above its envelope")
    func noPathToPermanentSilence() {
        // Sweep snooze × magnitude: anything above envelope re-alerts, always.
        for snooze in [nil, Date(timeIntervalSince1970: 2_000)] {
            var record = acked
            record.snoozeUntil = snooze
            for magnitude in stride(from: 226.0, through: 10_000, by: 500) {
                let decision = AcknowledgmentStore.evaluate(
                    record: record, currentMagnitude: magnitude, processStartAbsTime: 42,
                    now: Date(timeIntervalSince1970: 1_500)
                )
                #expect(decision == .realert(.materiallyWorse))
            }
        }
    }

    @Test("degenerate acked magnitude 0: any positive magnitude re-alerts")
    func zeroAckIsNoShield() {
        var zero = acked
        zero.acknowledgedMagnitude = 0
        #expect(AcknowledgmentStore.evaluate(record: zero, currentMagnitude: 0.1, processStartAbsTime: 42) == .realert(.materiallyWorse))
    }
}

@Suite("acknowledgment envelope — intent heuristic")
struct IntentHeuristicTests {
    @Test("foreground user app gets the higher default envelope")
    func foregroundUserApp() {
        let m = AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: "com.example.lmstudio", installSource: .userApplication, ownerIsRoot: false
        )
        #expect(m == AcknowledgmentDefaults.foregroundEnvelopeMultiplier)
        #expect(m == 2.0)
    }

    @Test("background root daemon does not")
    func rootDaemon() {
        let m = AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: nil, installSource: .appleSystem, ownerIsRoot: true
        )
        #expect(m == AcknowledgmentDefaults.backgroundEnvelopeMultiplier)
        #expect(m == 1.5)
    }

    @Test("root ownership disqualifies even a bundled user-path app")
    func rootBundledApp() {
        let m = AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: "com.example.agent", installSource: .userApplication, ownerIsRoot: true
        )
        #expect(m == 1.5)
    }

    @Test("bare executables (no bundle) are background-tier")
    func bareExecutable() {
        let m = AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: nil, installSource: .homebrew, ownerIsRoot: false
        )
        #expect(m == 1.5)
    }

    @Test("first-touch copy: soft for user apps, firm for background/root")
    func copyTone() {
        let soft = AcknowledgmentDefaults.ackPrompt(processName: "LM Studio", isUserForegroundApp: true)
        let firm = AcknowledgmentDefaults.ackPrompt(processName: "dasd", isUserForegroundApp: false)
        #expect(soft.contains("expected?"))
        #expect(firm.contains("never mutes"))
        #expect(soft != firm)
    }
}

@Suite("acknowledgment store — persistence + consume-on-realert")
struct AcknowledgmentStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ack-tests-\(UUID().uuidString)")
            .appending(path: "acknowledgments.json")
    }

    @Test("acknowledgments round-trip through acknowledgments.json")
    func persistenceRoundTrip() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = AcknowledgmentStore(fileURL: url)
        await store.loadIfNeeded()
        await store.acknowledge(key: "dasd|sustained_cpu|cpu_percent", magnitude: 150, envelopeMultiplier: 1.5, processStartAbsTime: 42)

        let reloaded = AcknowledgmentStore(fileURL: url)
        await reloaded.loadIfNeeded()
        let record = await reloaded.record(forKey: "dasd|sustained_cpu|cpu_percent")
        #expect(record?.acknowledgedMagnitude == 150)
        #expect(record?.envelopeMultiplier == 1.5)
        #expect(record?.processStartAbsTime == 42)
        #expect(record?.snoozeUntil == nil)
    }

    @Test("a re-alert spends the record — it can never suppress again")
    func realertConsumesRecord() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = AcknowledgmentStore(fileURL: url)
        await store.loadIfNeeded()
        await store.acknowledge(key: "k", magnitude: 100, envelopeMultiplier: 1.5, processStartAbsTime: 1)

        #expect(await store.decide(key: "k", currentMagnitude: 400, processStartAbsTime: 1) == .realert(.materiallyWorse))
        // Spent: the same condition now evaluates fresh.
        #expect(await store.decide(key: "k", currentMagnitude: 400, processStartAbsTime: 1) == .notAcknowledged)
    }

    @Test("suppress does NOT spend the record")
    func suppressKeepsRecord() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = AcknowledgmentStore(fileURL: url)
        await store.loadIfNeeded()
        await store.acknowledge(key: "k", magnitude: 100, envelopeMultiplier: 1.5, processStartAbsTime: 1)

        #expect(await store.decide(key: "k", currentMagnitude: 100, processStartAbsTime: 1) == .suppress)
        #expect(await store.decide(key: "k", currentMagnitude: 100, processStartAbsTime: 1) == .suppress)
        #expect(await store.count == 1)
    }

    @Test("record decode tolerates missing future fields (resilient decoding)")
    func resilientRecordDecode() throws {
        let json = #"{"acknowledgedMagnitude": 90, "processStartAbsTime": 7}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(AcknowledgmentRecord.self, from: json)
        #expect(record.acknowledgedMagnitude == 90)
        #expect(record.envelopeMultiplier == AcknowledgmentDefaults.realertMargin)
        #expect(record.snoozeUntil == nil)
    }
}
