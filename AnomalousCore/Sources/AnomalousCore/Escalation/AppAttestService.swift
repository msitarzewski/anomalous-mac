import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Supplies App Attest headers for an outgoing anonymous request. A nil provider
/// (e.g. the E2E CLI, which isn't a signed app) leaves the client on its dev
/// placeholder; the real `AppAttestService` returns genuine attestation headers.
public protocol AttestationProviding: Sendable {
    /// Headers to attach for a request whose body is exactly `body`. An empty
    /// dictionary means attestation is unavailable — the caller sends without
    /// them and the (fail-closed) server rejects, which is the correct outcome.
    func headers(for body: Data) async -> [String: String]
}

public enum AppAttestError: Error, Equatable {
    case unsupported
    case challengeFailed(Int)
    case registrationFailed(Int)
}

/// Real App Attest (`DCAppAttestService`): generates a Secure-Enclave key once,
/// registers it with the server (one-time challenge → attestation object), then
/// signs every request with a per-request assertion. The key id is not secret
/// (it identifies the sensor build, never a user — the ingest anonymity
/// invariant), so it persists in `UserDefaults`; the private key lives in the
/// Secure Enclave, referenced by that id.
///
/// The wire contract is verified end-to-end against the server in
/// AttestRegistrationTest: challenge → attestKey(SHA256(challenge)) →
/// POST /attest/register, then generateAssertion(SHA256(body)) per request.
public actor AppAttestService: AttestationProviding {
    private let baseURL: URL
    private let defaults: UserDefaults
    private static let keyIdKey = "appAttestKeyId"
    private static let registeredKey = "appAttestRegistered"

    /// Dedupes concurrent first-use so two requests don't both try to register.
    private var registration: Task<String, Error>?

    public init(baseURL: URL, defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.defaults = defaults
    }

    public func headers(for body: Data) async -> [String: String] {
        #if canImport(DeviceCheck)
        do {
            let keyId = try await ensureRegisteredKey()
            let clientDataHash = Data(SHA256.hash(data: body))
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
            return [
                "X-Anomalous-Key-Id": keyId,
                "X-Anomalous-Assertion": assertion.base64EncodedString(),
            ]
        } catch {
            // Fail closed: no valid attestation → no headers. Better a rejected
            // request than a placeholder that would poison the corpus if a
            // misconfigured server ever accepted it.
            return [:]
        }
        #else
        return [:]
        #endif
    }

    // MARK: - Registration

    private func ensureRegisteredKey() async throws -> String {
        if let keyId = defaults.string(forKey: Self.keyIdKey), defaults.bool(forKey: Self.registeredKey) {
            return keyId
        }
        if let registration { return try await registration.value }

        let task = Task { try await self.register() }
        registration = task
        defer { registration = nil }
        return try await task.value
    }

    #if canImport(DeviceCheck)
    private func register() async throws -> String {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw AppAttestError.unsupported }

        // attestKey is one-shot per key, so always start from a fresh key and
        // only persist it once the server has accepted the registration.
        let keyId = try await service.generateKey()
        do {
            let challenge = try await fetchChallenge()
            let attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: challenge)))
            try await postRegister(keyId: keyId, attestation: attestation, challenge: challenge)

            defaults.set(keyId, forKey: Self.keyIdKey)
            defaults.set(true, forKey: Self.registeredKey)
            return keyId
        } catch {
            // The key is now burned (attested, unregistered) or the network
            // failed — drop it so the next attempt generates a clean one.
            defaults.removeObject(forKey: Self.keyIdKey)
            defaults.set(false, forKey: Self.registeredKey)
            throw error
        }
    }

    /// POST /api/v1/attest/challenge → the one-time challenge (decoded bytes).
    private func fetchChallenge() async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: "/api/v1/attest/challenge"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AppAttestError.challengeFailed(code) }

        struct Body: Decodable { let challenge: String }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        guard let challenge = Data(base64Encoded: decoded.challenge) else {
            throw AppAttestError.challengeFailed(code)
        }
        return challenge
    }

    /// POST /api/v1/attest/register {key_id, attestation, challenge}.
    private func postRegister(keyId: String, attestation: Data, challenge: Data) async throws {
        var req = URLRequest(url: baseURL.appending(path: "/api/v1/attest/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "key_id": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ])

        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else { throw AppAttestError.registrationFailed(code) }
    }
    #else
    private func register() async throws -> String { throw AppAttestError.unsupported }
    #endif
}
