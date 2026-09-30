import Foundation

/// Account-linked triage escalation (the paid rung). Sends the on-device
/// PayloadComposer output to /api/v1/triage and polls for the diagnosis
/// card. Every send is logged byte-for-byte (SendLog, flow: .triage) —
/// the client half of the two-ledger transparency mechanism.
///
/// NOTE (architecture): v1 is a direct authenticated POST. The WWDC26 s339
/// custom-provider path (backend as a Foundation Models `LanguageModel`)
/// reuses this exact payload and can replace the transport later without
/// changing the composition or the send log.
public struct EscalationClient: Sendable {
    public struct Accepted: Sendable { public let id: Int }

    /// Retained before sending so a lost response can be retried without a new charge.
    public struct PendingSubmission: Codable, Sendable {
        public let idempotencyKey: UUID
        public let payload: PayloadComposer.TriagePayload
        public var acceptedID: Int?

        public init(payload: PayloadComposer.TriagePayload) {
            self.idempotencyKey = UUID()
            self.payload = payload
        }
    }

    /// The expert diagnosis returned by the recon backend — the same
    /// diagnosis-card shape the on-device model fills, plus cited evidence.
    public struct ExpertResult: Sendable, Equatable, Codable {
        public struct Evidence: Sendable, Equatable, Codable {
            public let url: String
            public let note: String
        }
        public var whatItIs: String?
        public var whyItsProbablyHot: String?
        public var isThisNormal: String?
        public var suggestedAction: String?
        public var actionSafetyTier: Int?
        public var evidence: [Evidence]
        /// Present when the backend couldn't reason (e.g. no provider) — an
        /// honest non-answer rather than a fabricated diagnosis.
        public var note: String?
    }

    public enum EscalationError: Error, Equatable {
        case unauthorized, insufficientBalance, requestRemoved, server(Int), timedOut, insecureTransport
    }

    /// Never send the account bearer token to a non-loopback host over cleartext
    /// HTTP. Loopback is allowed (local dev); anything else must be HTTPS.
    static func assertSecureTransport(_ url: URL) throws {
        do { try ServerOverridePolicy.assertSecureTransport(url) }
        catch { throw EscalationError.insecureTransport }
    }

    public let baseURL: URL
    public let bearerToken: String
    private let sendLog: SendLog

    public init(baseURL: URL, bearerToken: String, sendLog: SendLog) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.sendLog = sendLog
    }

    public func escalate(_ payload: PayloadComposer.TriagePayload, idempotencyKey: UUID = UUID()) async throws -> Accepted {
        try Self.assertSecureTransport(baseURL)
        let body = try JSONEncoder().encode(payload)
        _ = try await sendLog.record(flow: .triage, payload: body)

        var request = URLRequest(url: baseURL.appending(path: "/api/v1/triage"))
        request.httpMethod = "POST"
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await ServerOverridePolicy.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 202:
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            guard case let .number(id)? = decoded["id"] else { throw EscalationError.server(status) }
            return Accepted(id: Int(id))
        case 401: throw EscalationError.unauthorized
        case 402: throw EscalationError.insufficientBalance
        case 410: throw EscalationError.requestRemoved
        default: throw EscalationError.server(status)
        }
    }

    /// Poll GET /triage/{id} until the diagnosis is ready. This is the
    /// receive half — without it, escalation is fire-and-forget and the user
    /// never sees the answer they paid for.
    public func awaitResult(id: Int, attempts: Int = 20, interval: Duration = .seconds(2)) async throws -> ExpertResult {
        try Self.assertSecureTransport(baseURL)
        for _ in 0..<attempts {
            var request = URLRequest(url: baseURL.appending(path: "/api/v1/triage/\(id)"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await ServerOverridePolicy.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 404 || code == 410 { throw EscalationError.requestRemoved }
                if code == 401 { throw EscalationError.unauthorized }
                throw EscalationError.server(code)
            }
            let poll = try JSONDecoder().decode(TriagePollResponse.self, from: data)
            if poll.status == "complete" || poll.status == "failed", let result = poll.result {
                return result.toExpertResult()
            }
            try await Task.sleep(for: interval)
        }
        throw EscalationError.timedOut
    }
}

private struct TriagePollResponse: Decodable {
    let status: String
    let result: ResultBody?

    struct ResultBody: Decodable {
        let what_it_is: String?
        let why_its_probably_hot: String?
        let is_this_normal: String?
        let suggested_action: String?
        let action_safety_tier: Int?
        let evidence: [EscalationClient.ExpertResult.Evidence]?
        let note: String?

        func toExpertResult() -> EscalationClient.ExpertResult {
            .init(
                whatItIs: what_it_is, whyItsProbablyHot: why_its_probably_hot,
                isThisNormal: is_this_normal, suggestedAction: suggested_action,
                actionSafetyTier: action_safety_tier, evidence: evidence ?? [], note: note
            )
        }
    }
}

/// Minimal JSON value for decoding heterogeneous responses without a
/// bespoke struct per endpoint.
enum JSONValue: Decodable {
    case number(Double), string(String), bool(Bool), null, other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if c.decodeNil() { self = .null }
        else { self = .other }
    }
}
