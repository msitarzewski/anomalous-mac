import Foundation

/// Sends anonymous signatures to the ingestion API. Every send is recorded
/// byte-for-byte in the SendLog BEFORE it goes on the wire — auditable
/// beats approvable. Each request carries a real App Attest assertion over the
/// exact body (via `attestation`); a nil provider falls back to the dev
/// placeholder for the unsigned E2E CLI (production ingest refuses it by design).
public struct IngestClient: Sendable {
    public let baseURL: URL
    private let sendLog: SendLog
    private let attestation: AttestationProviding?

    public init(baseURL: URL, sendLog: SendLog, attestation: AttestationProviding? = nil) {
        self.baseURL = baseURL
        self.sendLog = sendLog
        self.attestation = attestation
    }

    @discardableResult
    public func send(_ anomaly: Anomaly) async throws -> Int {
        let body = try SignatureComposer.encode(SignatureComposer.compose(anomaly: anomaly))
        _ = try await sendLog.record(flow: .signature, payload: body)

        var request = URLRequest(url: baseURL.appending(path: "/api/v1/ingest"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (header, value) in await attestationHeaders(for: body) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Real App Attest headers over `body`, or the dev placeholder when no
    /// provider is configured (unsigned CLI against a dev server).
    private func attestationHeaders(for body: Data) async -> [String: String] {
        if let attestation {
            return await attestation.headers(for: body)
        }
        return [
            "X-Anomalous-Key-Id": "dev-placeholder-key",
            "X-Anomalous-Assertion": Data("placeholder".utf8).base64EncodedString(),
        ]
    }
}
