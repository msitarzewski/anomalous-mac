import Testing
import Foundation
@testable import AnomalousCore

@Suite("signature composer — anonymity is structural")
struct SignatureComposerTests {
    private func anomaly(bundleID: String? = nil) -> Anomaly {
        Anomaly(
            kind: .cpuTimeRatio,
            identity: ProcessIdentity(pid: 42, startAbsTime: 7, executableName: "dasd", bundleID: bundleID, appVersion: bundleID == nil ? nil : "1.2.3"),
            windowSeconds: 147_600,
            magnitudeCurve: [64.2],
            baselineValue: nil,
            detectedAt: Date(timeIntervalSince1970: 1_780_000_123) // mid-hour
        )
    }

    @Test("payload matches the wire schema shape and omits nil optionals")
    func schemaShape() throws {
        let data = try SignatureComposer.encode(SignatureComposer.compose(anomaly: anomaly()))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schema_version"] as? String == "0.1.0")
        #expect(json["platform"] as? String == "macos")
        let process = try #require(json["process"] as? [String: Any])
        #expect(process["kind"] as? String == "system_daemon")
        #expect(process["executable_name"] as? String == "dasd")
        #expect(process["bundle_id"] == nil)   // omitted, not null-boxed
        let body = try #require(json["anomaly"] as? [String: Any])
        #expect(body["type"] as? String == "cputime_ratio")
        #expect((body["magnitude_curve"] as? [Double])?.count == 1)
    }

    @Test("observed_at is truncated to the hour (timing-correlation resistance)")
    func hourTruncation() {
        let iso = SignatureComposer.hourTruncatedISO8601(Date(timeIntervalSince1970: 1_780_000_123))
        #expect(iso.hasSuffix(":00:00Z"))
    }

    @Test("no identifiable fields can exist — the payload type has no place for them")
    func structuralAnonymity() throws {
        let data = try SignatureComposer.encode(SignatureComposer.compose(anomaly: anomaly(bundleID: "com.example.app")))
        let raw = String(decoding: data, as: UTF8.self)
        // The composer never sees paths/usernames/args, so none can appear.
        #expect(!raw.contains(NSUserName()))
        #expect(!raw.contains("/Users/"))
        #expect(!raw.contains("user_id"))
    }
}
