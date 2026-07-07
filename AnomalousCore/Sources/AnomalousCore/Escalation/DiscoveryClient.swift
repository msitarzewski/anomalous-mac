import Foundation

/// Opt-in discovery for a GENUINELY unknown process — no corpus identity, and
/// the on-device model had no bundle to anchor on (a mystery daemon). Instead
/// of a shrug, ask the Anomalous API to research it and return a real answer,
/// "Sourced by Anomalous."
///
/// Anonymous like `IngestClient`: only the process name, bundle id (if any),
/// versions, install source, and anomaly type go on the wire — NEVER paths,
/// arguments, hostname, or anything identifiable (the `Request` type has no
/// field for them, so nothing identifiable CAN be composed). Every request is
/// recorded byte-for-byte in the `SendLog` (flow `.discovery`) BEFORE it is
/// sent — auditable beats approvable. The dev-placeholder attestation headers
/// mirror `IngestClient` until App Attest lands.
///
/// Flow: POST /api/v1/discover → 202 {discovery_id, status} to poll, OR a 200
/// cache-hit {status:"complete", assessment}. Then GET
/// /api/v1/discover/{discovery_id} → {status: researching|complete|unknown,
/// assessment?}. A `complete` assessment maps into a `DiagnosisCard`.
public struct DiscoveryClient: Sendable {
    public let baseURL: URL
    private let sendLog: SendLog

    public init(baseURL: URL, sendLog: SendLog) {
        self.baseURL = baseURL
        self.sendLog = sendLog
    }

    public enum DiscoveryError: Error, Equatable { case server(Int), timedOut }

    // MARK: - Request (anonymous by construction)

    public struct Request: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let name: String
        public let bundleID: String?
        public let appVersion: String?
        public let osVersion: String
        public let installSource: String?
        public let anomalyType: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case name
            case bundleID = "bundle_id"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case installSource = "install_source"
            case anomalyType = "anomaly_type"
        }
    }

    /// The researched assessment — the `DiagnosisCard` fields plus cited
    /// sources and provenance. `source` is "anomalous" for a grounded answer;
    /// `verified` marks a reviewed corpus entry.
    public struct Assessment: Sendable, Equatable, Decodable {
        public struct Source: Sendable, Equatable, Decodable {
            public let url: String
            public let note: String
        }
        public let whatItIs: String
        public let whyHot: String?
        public let isThisNormal: String
        public let suggestedAction: String?
        public let safetyTier: Int
        public let sources: [Source]
        public let source: String
        public let verified: Bool
        /// Research self-assessed confidence ("high"/"medium") for an UNVERIFIED
        /// answer the server returned anyway; nil for verified/corpus results.
        public let confidence: String?

        enum CodingKeys: String, CodingKey {
            case whatItIs = "what_it_is"
            case whyHot = "why_hot"
            case isThisNormal = "is_this_normal"
            case suggestedAction = "suggested_action"
            case safetyTier = "safety_tier"
            case sources
            case source
            case verified
            case confidence
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            whatItIs = try c.decode(String.self, forKey: .whatItIs)
            whyHot = try c.decodeIfPresent(String.self, forKey: .whyHot)
            isThisNormal = try c.decode(String.self, forKey: .isThisNormal)
            suggestedAction = try c.decodeIfPresent(String.self, forKey: .suggestedAction)
            safetyTier = try c.decodeIfPresent(Int.self, forKey: .safetyTier) ?? 3
            sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? "anomalous"
            verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
            confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        }

        public init(
            whatItIs: String, whyHot: String?, isThisNormal: String,
            suggestedAction: String?, safetyTier: Int, sources: [Source],
            source: String, verified: Bool, confidence: String? = nil
        ) {
            self.whatItIs = whatItIs
            self.whyHot = whyHot
            self.isThisNormal = isThisNormal
            self.suggestedAction = suggestedAction
            self.safetyTier = safetyTier
            self.sources = sources
            self.source = source
            self.verified = verified
            self.confidence = confidence
        }

        /// Whether this assessment is grounded by Anomalous research (vs a
        /// locally-composed card) — drives the "Sourced by Anomalous" label.
        public var isSourcedByAnomalous: Bool { source == "anomalous" }

        /// A confident-but-unverified research answer (returned to the requester
        /// but not published to the corpus) — captioned distinctly from a
        /// verified "Sourced by Anomalous" result.
        public var isUnverifiedResearch: Bool { !verified && source == "research" }

        /// Map into a `DiagnosisCard`. The detector's own baseline sentence
        /// (with the numbers) stays as `isThisNormal` — the card's prominent
        /// highlight — while the researched identity and "what this means"
        /// fill the rest.
        public func card(baselineSentence: String) -> DiagnosisCard {
            let means = [whyHot, isThisNormal]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let verdict = safetyTier >= 3
                ? DiagnosisCard.NormalVerdict.uncertain.rawValue
                : DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue
            return DiagnosisCard(
                whatItIs: whatItIs,
                whyItsProbablyHot: means.isEmpty ? whatItIs : means,
                isThisNormal: baselineSentence,
                suggestedAction: suggestedAction ?? "No specific action — this is informational.",
                actionSafetyTier: safetyTier,
                causallyLinkedProcesses: [],
                isThisNormalVerdict: verdict,
                confidenceNote: "Sourced by Anomalous\(verified ? " (verified from community-reviewed sources)" : "")."
            )
        }
    }

    public enum Status: String, Sendable, Equatable {
        case researching, complete, unknown
    }

    /// The POST result: accepted for research (202 → poll on `discoveryID`),
    /// or an immediate cache hit (200 → `assessment` already present).
    public struct Submission: Sendable, Equatable {
        public let discoveryID: String?
        public let status: Status
        public let assessment: Assessment?
    }

    /// One poll result.
    public struct PollResult: Sendable, Equatable {
        public let status: Status
        public let assessment: Assessment?
    }

    // MARK: - Compose

    /// Build the anonymous request from an anomaly. Pure + reusable — the app
    /// supplies the OS version. Structural anonymity: the `Request` type has no
    /// field for path/user/args, so nothing identifiable can be composed.
    public static func compose(anomaly: Anomaly, osVersion: String) -> Request {
        Request(
            schemaVersion: "0.1.0",
            name: anomaly.identity.executableName,
            bundleID: anomaly.identity.bundleID,
            appVersion: anomaly.identity.appVersion,
            osVersion: osVersion,
            // `.other` carries no signal — omit it rather than send noise.
            installSource: anomaly.identity.installSource == .other ? nil : anomaly.identity.installSource.rawValue,
            anomalyType: anomaly.kind.rawValue
        )
    }

    public static func encode(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    // MARK: - Send + poll

    /// POST /api/v1/discover. Logs the exact bytes FIRST, then sends. Returns
    /// the submission — 202 accepted (poll `discoveryID`) or 200 cache-hit
    /// (`assessment` ready).
    public func discover(_ request: Request) async throws -> Submission {
        let body = try Self.encode(request)
        _ = try await sendLog.record(flow: .discovery, payload: body)

        var req = URLRequest(url: baseURL.appending(path: "/api/v1/discover"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // TODO(App Attest): DCAppAttestService key + assertion headers.
        req.setValue("dev-placeholder-key", forHTTPHeaderField: "X-Anomalous-Key-Id")
        req.setValue(Data("placeholder".utf8).base64EncodedString(), forHTTPHeaderField: "X-Anomalous-Assertion")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 202 else { throw DiscoveryError.server(code) }
        return try Self.decodeSubmission(data)
    }

    /// GET /api/v1/discover/{id}. One poll — the CALLER drives the loop so it
    /// can stop the moment the popover closes (the result still lands in the
    /// corpus server-side for next time).
    public func poll(discoveryID: String) async throws -> PollResult {
        var req = URLRequest(url: baseURL.appending(path: "/api/v1/discover/\(discoveryID)"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DiscoveryError.server(code) }
        return try Self.decodePoll(data)
    }

    // MARK: - Decoding (snake_case wire → typed)

    static func decodeSubmission(_ data: Data) throws -> Submission {
        let raw = try JSONDecoder().decode(SubmissionBody.self, from: data)
        return Submission(
            discoveryID: raw.discovery_id,
            status: Status(rawValue: raw.status) ?? .researching,
            assessment: raw.assessment
        )
    }

    static func decodePoll(_ data: Data) throws -> PollResult {
        let raw = try JSONDecoder().decode(PollBody.self, from: data)
        return PollResult(
            status: Status(rawValue: raw.status) ?? .researching,
            assessment: raw.assessment
        )
    }

    private struct SubmissionBody: Decodable {
        let discovery_id: String?
        let status: String
        let assessment: Assessment?
    }

    private struct PollBody: Decodable {
        let status: String
        let assessment: Assessment?
    }
}
