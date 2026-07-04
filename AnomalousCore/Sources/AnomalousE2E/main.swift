import Foundation
import AnomalousCore

// ============================================================================
// End-to-end harness: real collector sample → detection rules (loosened
// thresholds so SOMETHING flags on a healthy machine) → the SAME
// SignatureComposer + IngestClient the app uses → POST /api/v1/ingest.
// Run: swift run AnomalousE2E [serverURL]
// ============================================================================

let server = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:8787"
print("AnomalousE2E → \(server)")

let collector = Collector()
let samples = await collector.sampleAll()
print("collector: \(samples.count) processes sampled")
guard !samples.isEmpty else {
    print("FAIL: collector returned no samples")
    exit(1)
}

// Demo thresholds: any process >5 min CPU at >2% lifetime ratio flags —
// guaranteed to catch something on a working machine without waiting 6h.
var thresholds = DetectionThresholds()
thresholds.cpuTimeRatio = 0.02
thresholds.cpuTimeRatioMinimumUptime = 300

let anomalies = samples.compactMap { sample -> Anomaly? in
    guard sample.cpuTimeSeconds > 300 else { return nil }
    return DetectionRules.cpuTimeRatioAnomaly(sample: sample, thresholds: thresholds)
}

guard let anomaly = anomalies.max(by: { ($0.magnitudeCurve.first ?? 0) < ($1.magnitudeCurve.first ?? 0) }) else {
    print("FAIL: no anomaly detected even with demo thresholds")
    exit(1)
}
print("detected: \(anomaly.kind.rawValue) in \(anomaly.identity.executableName) (\(anomaly.identity.bundleID ?? "no bundle"))")

let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("anomalous-sendlog")
let client = IngestClient(baseURL: URL(string: server)!, sendLog: SendLog(directory: logDirectory))

do {
    let status = try await client.send(anomaly)
    print("server: HTTP \(status) · send log: \(logDirectory.path)")
    if status == 202 {
        print("E2E OK: sensor → detection → signature → ingest accepted")
        exit(0)
    }
    print("E2E FAIL: expected 202, got \(status)")
    exit(1)
} catch {
    print("E2E FAIL: \(error.localizedDescription) — is the server running? (cd server && php artisan serve --port 8787)")
    exit(1)
}
