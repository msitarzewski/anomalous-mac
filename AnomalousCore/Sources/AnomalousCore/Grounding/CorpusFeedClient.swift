import Foundation
import CryptoKit

/// One published corpus entry as served by `/v1/feed` — the sensor's
/// `KnowledgeEntry` plus provenance (`sources`, `platform`, `corrected_by`),
/// snake_case on the wire. `safe_action: null` is SEMANTIC — "no safe
/// intervention exists" (22 of the 61 tier-3 entries) — not a missing field:
/// the merged entry keeps its tier and offers no action.
public struct CorpusFeedEntry: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public let url: String?
        public let note: String?

        public init(url: String?, note: String?) {
            self.url = url
            self.note = note
        }
    }

    public let processName: String
    public let displayName: String
    public let whatItIs: String
    public let ownedBy: String
    public let whenHotImplies: String
    public let safetyTier: Int
    public let safeAction: String?
    public let worstCase: String?
    public let causallyLinked: [String]?
    public let sources: [Source]?
    public let platform: String?
    public let correctedBy: String?

    enum CodingKeys: String, CodingKey {
        case processName = "process_name"
        case displayName = "display_name"
        case whatItIs = "what_it_is"
        case ownedBy = "owned_by"
        case whenHotImplies = "when_hot_implies"
        case safetyTier = "safety_tier"
        case safeAction = "safe_action"
        case worstCase = "worst_case"
        case causallyLinked = "causally_linked"
        case sources
        case platform
        case correctedBy = "corrected_by"
    }

    public init(
        processName: String, displayName: String, whatItIs: String, ownedBy: String,
        whenHotImplies: String, safetyTier: Int, safeAction: String?, worstCase: String?,
        causallyLinked: [String]?, sources: [Source]? = nil, platform: String? = nil, correctedBy: String? = nil
    ) {
        self.processName = processName
        self.displayName = displayName
        self.whatItIs = whatItIs
        self.ownedBy = ownedBy
        self.whenHotImplies = whenHotImplies
        self.safetyTier = safetyTier
        self.safeAction = safeAction
        self.worstCase = worstCase
        self.causallyLinked = causallyLinked
        self.sources = sources
        self.platform = platform
        self.correctedBy = correctedBy
    }

    /// The grounding shape the judgment layer consumes.
    public var knowledgeEntry: KnowledgeEntry {
        KnowledgeEntry(
            processName: processName, displayName: displayName, whatItIs: whatItIs,
            ownedBy: ownedBy, whenHotImplies: whenHotImplies, safetyTier: safetyTier,
            safeAction: safeAction, worstCase: worstCase, causallyLinked: causallyLinked ?? []
        )
    }
}

/// Pinned Ed25519 feed-signing public keys, `{key_id: base64 raw pubkey}` —
/// rotation-ready. The production map is EMPTY until a `php artisan
/// feed:keygen` run mints the key; with an empty map a `requireSignedFeed`
/// client rejects every signed feed (fail closed) and keeps the shipped +
/// last-verified corpus. Injectable so tests pin their own throwaway key.
public struct CorpusFeedKeys: Sendable {
    public let keys: [String: String]

    public init(keys: [String: String]) {
        self.keys = keys
    }

    /// PINNED PRODUCTION KEYS — fill from `php artisan feed:keygen` output.
    public static let pinned = CorpusFeedKeys(keys: [:])
}

/// The last VERIFIED corpus, persisted to Application Support so cards stay
/// grounded offline and a rejected update can never displace good data.
///
/// The FULL signed envelope is stored — the `data` array plus its `signature`,
/// `key_id`, and `signed_at` — NOT the decoded entries. The store lives in a
/// user-domain file that any same-user process can overwrite (the app is not
/// sandboxed), so the signature is re-verified on every load: a poisoned cache
/// (e.g. malware mislabeling itself `safety_tier:3, owned_by:"Apple"`) fails
/// the check and is discarded. An old entries-only file has no `data`/
/// `signature` and is likewise treated as unverified and dropped.
public struct PersistedCorpus: Codable, Sendable {
    public let fetchedAt: Date
    public let keyID: String?
    public let signedAt: String?
    public let signature: String?
    /// The verified envelope's `data` array, re-canonicalized and re-verified
    /// on load. `nil` for a legacy entries-only file → discarded as unverified.
    public let data: [CanonicalJSONValue]?

    public init(
        fetchedAt: Date,
        keyID: String?,
        signedAt: String?,
        signature: String?,
        data: [CanonicalJSONValue]?
    ) {
        self.fetchedAt = fetchedAt
        self.keyID = keyID
        self.signedAt = signedAt
        self.signature = signature
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case fetchedAt, keyID, signedAt, signature, data
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
        signedAt = try c.decodeIfPresent(String.self, forKey: .signedAt)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        // Absent on a legacy entries-only file — decodes to nil, which the
        // loader treats as unverified and discards.
        data = try c.decodeIfPresent([CanonicalJSONValue].self, forKey: .data)
    }
}

/// Pulls `/v1/feed`, verifies the Ed25519 signature over the canonical JSON
/// of `data`, and persists the verified corpus for local, offline matching —
/// the privacy-critical half of the corpus loop: identities NEVER require a
/// per-lookup server round-trip.
///
/// POLICY: with `requireSignedFeed` (release default) an unsigned envelope
/// (`signature: null`) or a verification failure REJECTS the update and the
/// last verified corpus stays authoritative — unsigned == tampered. Dev
/// builds may set it false to accept unsigned local feeds; a PRESENT but
/// invalid signature is rejected in both modes.
public struct CorpusFeedClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum RefreshOutcome: Sendable, Equatable {
        /// Verified (or dev-accepted unsigned) corpus persisted.
        case updated(entryCount: Int)
        /// Legacy envelope without `data` — nothing to ground from; the
        /// shipped map + last persisted corpus stand (never gate on
        /// schema_version; feature-detect `data`).
        case noCorpusData
        /// `signature: null` under the release policy — last-good kept.
        case rejectedUnsigned
        /// Bad/unknown signature or non-canonical data — last-good kept.
        case rejectedBadSignature(String)
        /// `refreshIfStale` found the persisted corpus recent enough.
        case skippedFresh
    }

    public enum FeedError: Error, Equatable {
        case httpStatus(Int)
    }

    public let baseURL: URL
    public let keys: CorpusFeedKeys
    public let requireSignedFeed: Bool
    public let storeURL: URL
    private let transport: Transport

    public init(
        baseURL: URL,
        keys: CorpusFeedKeys = .pinned,
        requireSignedFeed: Bool = true,
        storeURL: URL? = nil,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.keys = keys
        self.requireSignedFeed = requireSignedFeed
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.transport = transport
    }

    /// Application Support/Anomalous/corpus-feed.json — survives app updates.
    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Anomalous/corpus-feed.json")
    }

    // MARK: - Refresh

    /// Fetch + verify + persist. Network/HTTP errors throw (the caller's
    /// retry concern); verification failures return a rejection outcome and
    /// KEEP the last verified corpus on disk untouched.
    public func refresh(now: Date = Date()) async throws -> RefreshOutcome {
        var request = URLRequest(url: baseURL.appending(path: "/v1/feed"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FeedError.httpStatus(status) }
        return verifyAndPersist(envelopeBody: body, now: now)
    }

    /// The app's cadence hook: refresh at most once per `hours` (default 24),
    /// judged from the persisted corpus's own fetch date.
    public func refreshIfStale(hours: Double = 24, now: Date = Date()) async throws -> RefreshOutcome {
        // Only a VERIFIABLE cache counts as fresh — otherwise an attacker who
        // overwrites the store with a far-future `fetchedAt` could suppress
        // refreshes and pin a poisoned (but now-rejected) cache in place.
        if let persisted = loadPersisted(),
           now.timeIntervalSince(persisted.fetchedAt) < hours * 3600,
           loadVerifiedEntries() != nil {
            return .skippedFresh
        }
        return try await refresh(now: now)
    }

    /// Envelope → verification policy → persistence. Split from the network
    /// so the whole trust path is fixture-testable byte-for-byte.
    func verifyAndPersist(envelopeBody: Data, now: Date) -> RefreshOutcome {
        let envelope: FeedEnvelope
        do {
            envelope = try JSONDecoder().decode(FeedEnvelope.self, from: envelopeBody)
        } catch {
            return .rejectedBadSignature("undecodable envelope: \(error)")
        }
        guard let data = envelope.data else { return .noCorpusData }

        let canonical: Data
        do {
            canonical = try CanonicalJSONValue.canonicalBytes(of: .array(data))
        } catch {
            return .rejectedBadSignature("data outside the canonical value domain: \(error)")
        }

        if let signature = envelope.signature, let keyID = envelope.keyID {
            // Signed: verify against the pinned key in BOTH policies — a
            // present-but-wrong signature is tampering, never acceptable.
            guard let pinned = keys.keys[keyID] else {
                return .rejectedBadSignature("no pinned key for key_id '\(keyID)'")
            }
            guard let keyBytes = Data(base64Encoded: pinned),
                  let signatureBytes = Data(base64Encoded: signature),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
                  publicKey.isValidSignature(signatureBytes, for: canonical)
            else {
                return .rejectedBadSignature("Ed25519 verification failed for key_id '\(keyID)'")
            }
        } else if requireSignedFeed {
            // Release policy: unsigned == tampered. Last verified corpus stays.
            return .rejectedUnsigned
        }

        let entries: [CorpusFeedEntry]
        do {
            entries = try JSONDecoder().decode([CorpusFeedEntry].self, from: canonical)
        } catch {
            return .rejectedBadSignature("verified data does not decode as corpus entries: \(error)")
        }

        // Persist the FULL verified envelope (data + signature + key_id +
        // signed_at), not the decoded entries — so the next load can re-run
        // the exact same Ed25519 check against a possibly-tampered file.
        persist(PersistedCorpus(
            fetchedAt: now,
            keyID: envelope.keyID,
            signedAt: envelope.signedAt,
            signature: envelope.signature,
            data: data
        ))
        return .updated(entryCount: entries.count)
    }

    /// Re-run the network path's verification over a persisted envelope's
    /// `data`: canonicalize, verify the Ed25519 signature against the pinned
    /// key (present-but-wrong is rejected in both policies; unsigned is
    /// rejected only under `requireSignedFeed`), then decode entries. Returns
    /// nil — meaning "discard, fall back to the shipped map" — on any failure.
    func verifiedEntries(data: [CanonicalJSONValue], signature: String?, keyID: String?) -> [CorpusFeedEntry]? {
        guard let canonical = try? CanonicalJSONValue.canonicalBytes(of: .array(data)) else { return nil }

        if let signature, let keyID {
            guard let pinned = keys.keys[keyID],
                  let keyBytes = Data(base64Encoded: pinned),
                  let signatureBytes = Data(base64Encoded: signature),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
                  publicKey.isValidSignature(signatureBytes, for: canonical)
            else { return nil }
        } else if requireSignedFeed {
            return nil
        }

        return try? JSONDecoder().decode([CorpusFeedEntry].self, from: canonical)
    }

    // MARK: - Persistence + local match

    func persist(_ corpus: PersistedCorpus) {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(corpus).write(to: storeURL, options: .atomic)
        } catch {
            // A failed write must never take the app down; the previous
            // persisted corpus (if any) simply stays authoritative.
        }
    }

    public func loadPersisted() -> PersistedCorpus? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedCorpus.self, from: data)
    }

    /// The persisted corpus re-verified on load: entries only if the on-disk
    /// envelope still passes the pinned-key Ed25519 check. A tampered file, a
    /// missing pinned key, or a legacy entries-only file (no `data`) yields nil
    /// — and callers fall back to the safe shipped map.
    func loadVerifiedEntries() -> [CorpusFeedEntry]? {
        guard let persisted = loadPersisted(), let data = persisted.data else { return nil }
        return verifiedEntries(data: data, signature: persisted.signature, keyID: persisted.keyID)
    }

    /// The pulled entries that apply locally — matched on
    /// (process_name, platform == 'macos'); a missing platform is treated as
    /// macOS (the feed's founding platform). Verified on load; an unverifiable
    /// cache grounds nothing (the shipped map stands).
    public func persistedKnowledgeEntries(platform: String = "macos") -> [KnowledgeEntry] {
        guard let entries = loadVerifiedEntries() else { return [] }
        return entries
            .filter { ($0.platform ?? "macos") == platform }
            .map(\.knowledgeEntry)
    }

    /// Shipped map + pulled corpus, pulled WINS on the same process name —
    /// it's reviewed and newer than the app bundle.
    public func mergedKnowledgeMap(base: KnowledgeMap) -> KnowledgeMap {
        base.merging(pulled: persistedKnowledgeEntries())
    }
}

/// `/v1/feed` envelope — additive over the legacy known-issues feed. Only
/// the corpus fields matter here; `issues` stays byte-identical for its
/// existing consumer. Feature-detect `data`; never gate on schema_version.
struct FeedEnvelope: Decodable {
    let data: [CanonicalJSONValue]?
    let signature: String?
    let keyID: String?
    let signedAt: String?

    enum CodingKeys: String, CodingKey {
        case data
        case signature
        case keyID = "key_id"
        case signedAt = "signed_at"
    }
}
