import Foundation
import Security
import Testing
@testable import AnomalousCore

// Phase 4: the App Group wire shapes (widget status + commands) and the
// journal's resolution back-compat. These are the pure halves of the widget
// and intents integration — what CAN be tested in core; the intent handlers
// themselves need an app-target test host (documented in the phase report).

@Suite("sensor status — widget state JSON")
struct SensorStatusTests {
    @Test("status round-trips through JSON, top card intact")
    func roundTrip() throws {
        let status = SensorStatus(
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            monitoringEnabled: true,
            activeCount: 1,
            quietCount: 3,
            watchedProcessCount: 612,
            topCard: .init(
                processName: "dasd",
                kind: "sustained_cpu",
                summary: "A background scheduler stuck in a retry loop.",
                safetyTier: 2,
                conditionKey: "dasd|sustained_cpu|cpu_percent",
                returnedWorse: true
            )
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SensorStatus.self, from: data)
        #expect(decoded == status)
    }

    @Test("file write/read helpers round-trip")
    func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "status-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = SensorStatus.fileURL(in: dir)

        let status = SensorStatus(activeCount: 0, quietCount: 2, watchedProcessCount: 500)
        try status.write(to: url)
        let read = SensorStatus.read(from: url)
        #expect(read == status)
        #expect(SensorStatus.read(from: dir.appending(path: "missing.json")) == nil)
    }

    @Test("decode tolerates a minimal/older status payload")
    func resilientDecode() throws {
        let json = #"{"activeCount": 2}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(SensorStatus.self, from: json)
        #expect(status.activeCount == 2)
        #expect(status.monitoringEnabled == true)
        #expect(status.topCard == nil)
    }

    @Test("summary line: nominal, anomalous, and paused")
    func summaryLines() {
        let nominal = SensorStatus(activeCount: 0, quietCount: 0, watchedProcessCount: 400)
        #expect(nominal.summaryLine.contains("all systems nominal"))
        #expect(nominal.summaryLine.contains("400"))

        let quiet = SensorStatus(activeCount: 0, quietCount: 2, watchedProcessCount: 400)
        #expect(quiet.summaryLine.contains("2 low-confidence observations"))

        let anomalous = SensorStatus(
            activeCount: 1, quietCount: 0, watchedProcessCount: 400,
            topCard: .init(processName: "dasd", kind: "sustained_cpu", summary: "Stuck retry loop.", safetyTier: 2, conditionKey: "k")
        )
        #expect(anomalous.summaryLine.contains("1 anomaly needs attention"))
        #expect(anomalous.summaryLine.contains("dasd"))

        let paused = SensorStatus(monitoringEnabled: false)
        #expect(paused.summaryLine.contains("paused"))
    }
}

@Suite("widget commands — queue in the App Group container")
struct WidgetCommandTests {
    @Test("enqueue + drain round-trips and clears the queue")
    func enqueueDrain() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cmd-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = WidgetCommand.fileURL(in: dir)

        WidgetCommand.enqueue(WidgetCommand(action: .acknowledge, conditionKey: "k1"), at: url)
        WidgetCommand.enqueue(WidgetCommand(action: .snoozeCondition, conditionKey: "k1", snoozeSeconds: 3600), at: url)

        let drained = WidgetCommand.drain(at: url)
        #expect(drained.count == 2)
        #expect(drained[0].action == .acknowledge)
        #expect(drained[1].snoozeSeconds == 3600)
        // Queue is consumed.
        #expect(WidgetCommand.drain(at: url).isEmpty)
    }

    @Test("stale commands (>10 min) are dropped at drain")
    func staleDropped() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cmd-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = WidgetCommand.fileURL(in: dir)

        let old = WidgetCommand(action: .runScan, issuedAt: Date(timeIntervalSinceNow: -3600))
        let fresh = WidgetCommand(action: .runScan)
        WidgetCommand.enqueue(old, at: url)
        WidgetCommand.enqueue(fresh, at: url)

        let drained = WidgetCommand.drain(at: url)
        #expect(drained.count == 1)
        #expect(drained[0].issuedAt == fresh.issuedAt)
    }
}

@Suite("widget command authentication — HMAC + replay + clamp (App Group is attacker-writable)")
struct WidgetCommandAuthTests {
    private func randomKey() -> Data {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return bytes
    }

    /// A signed command survives a JSON round-trip (the wire path) and still
    /// authenticates — the signing string must be byte-stable across encode.
    @Test("a validly signed command is accepted, before and after a JSON round-trip")
    func validMacAccepted() throws {
        let key = randomKey()
        let signed = WidgetCommand(action: .snoozeCondition, conditionKey: "dasd|sustained_cpu|cpu_percent", snoozeSeconds: 3600)
            .signed(with: key)
        #expect(signed.isAuthentic(key: key))

        let wire = try JSONDecoder().decode(WidgetCommand.self, from: JSONEncoder().encode(signed))
        #expect(wire.isAuthentic(key: key))
    }

    @Test("a forged command (no MAC) or one signed with another key is rejected")
    func forgedRejected() {
        let key = randomKey()
        // Malware drops a raw, unsigned command into the container.
        let unsigned = WidgetCommand(action: .setMonitoring, monitoringEnabled: false)
        #expect(!unsigned.isAuthentic(key: key))
        // Or signs with a key it doesn't have (a different one).
        let wrong = unsigned.signed(with: randomKey())
        #expect(!wrong.isAuthentic(key: key))
    }

    @Test("tampering any signed field invalidates the MAC")
    func tamperedFieldFailsMac() {
        let key = randomKey()
        var cmd = WidgetCommand(action: .snoozeAll, snoozeSeconds: 3600).signed(with: key)
        #expect(cmd.isAuthentic(key: key))
        // Flip the snooze to a century — the MAC no longer matches.
        cmd.snoozeSeconds = 100 * 365 * 86_400
        #expect(!cmd.isAuthentic(key: key))
    }

    @Test("a replayed nonce is rejected on the second sight")
    func replayRejected() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nonce-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SeenNonceStore(fileURL: dir.appending(path: "widget-nonces.json"))

        let nonce = UUID().uuidString
        #expect(store.claim(nonce) == true)   // first sight: fresh
        #expect(store.claim(nonce) == false)  // replay: rejected
        #expect(store.claim("") == false)     // empty nonce is never valid
    }

    @Test("the seen-nonce ring stays bounded and still rejects a recent replay")
    func nonceRingBounded() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nonce-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SeenNonceStore(fileURL: dir.appending(path: "widget-nonces.json"), capacity: 4)

        let recent = UUID().uuidString
        #expect(store.claim(recent) == true)
        for _ in 0..<3 { #expect(store.claim(UUID().uuidString) == true) }
        // `recent` is still within the last 4 → its replay is still caught.
        #expect(store.claim(recent) == false)
    }

    @Test("snooze is clamped to 24h regardless of what the command claims")
    func snoozeClamped() {
        let century = WidgetCommand(action: .snoozeAll, snoozeSeconds: 100 * 365 * 86_400)
        #expect(century.clampedSnoozeSeconds(default: 3600) == WidgetCommand.maxSnoozeSeconds)
        // A normal value passes through untouched.
        let hour = WidgetCommand(action: .snoozeCondition, conditionKey: "k", snoozeSeconds: 3600)
        #expect(hour.clampedSnoozeSeconds(default: 1800) == 3600)
        // A missing value falls back to the default (itself clamped).
        let none = WidgetCommand(action: .snoozeAll)
        #expect(none.clampedSnoozeSeconds(default: 3600) == 3600)
    }
}

@Suite("anomaly resolution — Phase 4 cases + back-compat")
struct ResolutionCompatTests {
    @Test("acknowledged and snoozed round-trip")
    func newCasesRoundTrip() throws {
        for resolution in [AnomalyResolution.acknowledged, .snoozed] {
            let data = try JSONEncoder().encode(resolution)
            let decoded = try JSONDecoder().decode(AnomalyResolution.self, from: data)
            #expect(decoded == resolution)
        }
    }

    @Test("old journal values still decode")
    func oldValuesDecode() throws {
        for raw in ["recovered", "ended", "dismissed", "actioned"] {
            let decoded = try JSONDecoder().decode(AnomalyResolution.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
        }
    }

    @Test("unknown future resolution degrades to .dismissed instead of throwing")
    func unknownDegrades() throws {
        let decoded = try JSONDecoder().decode(AnomalyResolution.self, from: Data(#""escalated_v9""#.utf8))
        #expect(decoded == .dismissed)
    }

    @Test("a journal entry with a Phase-4 resolution decodes inside a full snapshot")
    func journalEntryWithNewResolution() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "journal-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "journal.json")

        let journal = AnomalyJournal(fileURL: url)
        await journal.loadIfNeeded()
        await journal.record(JournalEntry(
            processName: "LM Studio", bundleID: "com.example.lmstudio", kind: "sustained_cpu",
            summary: "Local model inference.", action: "None needed.", safetyTier: 1,
            judgedByModel: true, detectedAt: .now, resolution: .acknowledged
        ))

        let reloaded = AnomalyJournal(fileURL: url)
        await reloaded.loadIfNeeded()
        let entries = await reloaded.recent()
        #expect(entries.count == 1)
        #expect(entries[0].resolution == .acknowledged)
        #expect(entries[0].resolution.label == "Marked normal")
    }
}
