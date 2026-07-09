import Testing
import Foundation
@testable import AnomalousCore

@Suite("escalation payload — composed from safe fields only")
struct EscalationPayloadTests {
    private func anomaly() -> Anomaly {
        Anomaly(
            kind: .sustainedCPU,
            identity: ProcessIdentity(pid: 42, startAbsTime: 7, executableName: "mediaanalysisd"),
            windowSeconds: 1800, magnitudeCurve: [150, 148, 151], baselineValue: 0.5, detectedAt: .now
        )
    }

    @Test("triage payload carries only safe fields — no path/user/args possible")
    func safeComposition() throws {
        let payload = PayloadComposer().compose(
            anomaly: anomaly(),
            baselineSentence: "averaged 0.5% for 90 days; at 150% for 41 hours",
            osVersion: "27.0",
            hardwareClass: "mac17,6"
        )
        let raw = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(raw.contains("mediaanalysisd"))
        #expect(raw.contains("41 hours"))
        // Structural anonymity: the composer never receives these, so they
        // cannot appear regardless of the summary text.
        #expect(!raw.contains(NSUserName()))
        #expect(!raw.contains("/Users/"))
        #expect(!raw.contains("--"))   // no command-line flags
    }

    @Test("metric_curves is never empty — EVERY anomaly kind maps to a curve, or the server 422s the whole request")
    func metricCurvesNeverEmpty() throws {
        for kind in Anomaly.Kind.allCases {
            let a = Anomaly(
                kind: kind,
                identity: ProcessIdentity(pid: 1, startAbsTime: 1, executableName: "someproc", bundleID: "com.example.App"),
                windowSeconds: 1800, magnitudeCurve: [10, 20, 30], baselineValue: 5, detectedAt: .now
            )
            let payload = PayloadComposer().compose(anomaly: a, baselineSentence: "b", osVersion: "27.0", hardwareClass: "x")
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
            let curves = obj["metric_curves"] as? [String: Any]
            #expect(curves != nil && !(curves!.isEmpty),
                    "metric_curves empty for kind \(kind.rawValue) — this 422s at the server's required rule and breaks Get Help")
        }
    }

    @Test("escalation client logs the exact bytes before sending")
    func logsBeforeSend() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "esc-test-\(UUID().uuidString)")
        let log = SendLog(directory: dir)
        let client = EscalationClient(baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "t", sendLog: log)
        let payload = PayloadComposer().compose(anomaly: anomaly(), baselineSentence: "b", osVersion: "27.0", hardwareClass: "x")
        // Connection will fail (port 1), but the send log must already hold
        // the payload — auditable beats approvable.
        _ = try? await client.escalate(payload)
        let entries = await log.all()
        #expect(entries.count == 1)
        #expect(entries.first?.flow == .triage)
    }
}
