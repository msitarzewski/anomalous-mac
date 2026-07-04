import Foundation

/// Sends anonymous signatures to the ingestion API. Every send is recorded
/// byte-for-byte in the SendLog BEFORE it goes on the wire — auditable
/// beats approvable. Attestation headers are dev placeholders until
/// App Attest lands (production ingest refuses them by design).
public struct IngestClient: Sendable {
    public let baseURL: URL
    private let sendLog: SendLog

    public init(baseURL: URL, sendLog: SendLog) {
        self.baseURL = baseURL
        self.sendLog = sendLog
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
        // TODO(App Attest): DCAppAttestService key + assertion headers.
        request.setValue("dev-placeholder-key", forHTTPHeaderField: "X-Anomalous-Key-Id")
        request.setValue(Data("placeholder".utf8).base64EncodedString(), forHTTPHeaderField: "X-Anomalous-Assertion")

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
