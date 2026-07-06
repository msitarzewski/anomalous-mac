import Testing
import Foundation
import CryptoKit
@testable import AnomalousCore

@Suite("corpus feed — pull, verify, persist, merge (Phase-6 sensor half)")
struct CorpusFeedTests {
    // Two corpus entries exercising the canonicalization corners: keys out
    // of asciibetical order, slashes in URLs, unicode, nested objects,
    // semantic null (safe_action), ints.
    static let dataJSON = """
    [
      {"what_it_is":"Apple's background-activity scheduler — updated from the fleet.",
       "process_name":"dasd",
       "display_name":"Duet Activity Scheduler",
       "owned_by":"Apple (system daemon, launchd-managed)",
       "when_hot_implies":"A wedged scheduling loop; on 27 betas a known BiomeAgent leak.",
       "safety_tier":1,
       "safe_action":"kill — launchd respawns it fresh within seconds",
       "worst_case":"A deferred task runs later.",
       "causally_linked":["appstoreagent","BiomeAgent"],
       "sources":[{"url":"https://example.com/dasd/analysis","note":"fleet café review — émigré build"}],
       "platform":"macos",
       "corrected_by":null},
      {"process_name":"cloudphotod",
       "display_name":"iCloud Photos Daemon",
       "what_it_is":"Syncs the Photos library with iCloud.",
       "owned_by":"Apple",
       "when_hot_implies":"A large library sync or a stuck upload.",
       "safety_tier":3,
       "safe_action":null,
       "worst_case":null,
       "causally_linked":[],
       "sources":[],
       "platform":"macos",
       "corrected_by":null}
    ]
    """

    /// Canonical bytes of the data array — exactly what the server signs.
    static func canonicalData() throws -> Data {
        let values = try JSONDecoder().decode([CanonicalJSONValue].self, from: Data(dataJSON.utf8))
        return try CanonicalJSONValue.canonicalBytes(of: .array(values))
    }

    static func envelope(dataJSON: String, signature: String?, keyID: String?) -> Data {
        let sig = signature.map { "\"\($0)\"" } ?? "null"
        let kid = keyID.map { "\"\($0)\"" } ?? "null"
        let signedAt = signature == nil ? "null" : "\"2026-07-05T00:00:00Z\""
        return Data("""
        {"schema_version":"0.1.0","issues":[],"data":\(dataJSON),"signed_at":\(signedAt),"signature":\(sig),"key_id":\(kid)}
        """.utf8)
    }

    static func transport(returning body: Data, status: Int = 200) -> CorpusFeedClient.Transport {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
    }

    private func makeClient(
        body: Data,
        keys: [String: String],
        requireSigned: Bool = true,
        storeURL: URL
    ) -> CorpusFeedClient {
        CorpusFeedClient(
            baseURL: URL(string: "https://feed.test")!,
            keys: CorpusFeedKeys(keys: keys),
            requireSignedFeed: requireSigned,
            storeURL: storeURL,
            transport: Self.transport(returning: body)
        )
    }

    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "corpus-test-\(UUID().uuidString)/corpus-feed.json")
    }

    @Test("valid signed feed verifies (Ed25519 over canonical JSON) and merges, pulled wins over shipped")
    func signedFeedVerifiesAndMerges() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.canonicalData()).base64EncodedString()
        let pubkey = key.publicKey.rawRepresentation.base64EncodedString()
        let store = tempStore()
        let client = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: signature, keyID: "k1"),
            keys: ["k1": pubkey], storeURL: store
        )

        let outcome = try await client.refresh()
        #expect(outcome == .updated(entryCount: 2))

        // Local match: persisted, offline-capable, platform-filtered.
        let pulled = client.persistedKnowledgeEntries()
        #expect(pulled.count == 2)

        // Merge: the pulled dasd entry (reviewed, newer) WINS over shipped.
        let shipped = try KnowledgeMap.shipped()
        let shippedDasd = try #require(shipped.entry(forProcessName: "dasd"))
        #expect(!shippedDasd.whatItIs.contains("updated from the fleet"))
        let merged = client.mergedKnowledgeMap(base: shipped)
        let mergedDasd = try #require(merged.entry(forProcessName: "dasd"))
        #expect(mergedDasd.whatItIs.contains("updated from the fleet"))
        // Non-colliding shipped entries survive the merge.
        #expect(merged.entry(forProcessName: "mysqld") != nil)
        #expect(merged.count == shipped.count + 1) // dasd replaced, cloudphotod added
    }

    @Test("tampered data is rejected and the last verified corpus is kept")
    func tamperRejectedLastGoodKept() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.canonicalData()).base64EncodedString()
        let pubkey = key.publicKey.rawRepresentation.base64EncodedString()
        let store = tempStore()

        // First, a good verified pull.
        let good = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: signature, keyID: "k1"),
            keys: ["k1": pubkey], storeURL: store
        )
        #expect(try await good.refresh() == .updated(entryCount: 2))

        // Then a tampered body under the SAME (valid-for-original) signature:
        // the attacker flips safety_tier 3 → 1 to mint a kill button.
        let tampered = Self.dataJSON.replacingOccurrences(of: "\"safety_tier\":3", with: "\"safety_tier\":1")
        let bad = makeClient(
            body: Self.envelope(dataJSON: tampered, signature: signature, keyID: "k1"),
            keys: ["k1": pubkey], storeURL: store
        )
        let outcome = try await bad.refresh()
        guard case .rejectedBadSignature = outcome else {
            Issue.record("tampered feed accepted: \(outcome)")
            return
        }
        // Last-good stands: cloudphotod still tier 3, no minted action.
        let entries = bad.persistedKnowledgeEntries()
        let cloudphotod = try #require(entries.first { $0.processName == "cloudphotod" })
        #expect(cloudphotod.safetyTier == 3)
        #expect(cloudphotod.safeAction == nil)
    }

    @Test("unknown key_id is rejected — rotation never falls back to trust")
    func unknownKeyRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.canonicalData()).base64EncodedString()
        let client = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: signature, keyID: "k2"),
            keys: ["k1": key.publicKey.rawRepresentation.base64EncodedString()],
            storeURL: tempStore()
        )
        guard case .rejectedBadSignature = try await client.refresh() else {
            Issue.record("unknown key_id accepted")
            return
        }
    }

    @Test("unsigned feed: rejected under the release policy, accepted in dev")
    func unsignedPolicy() async throws {
        let unsigned = Self.envelope(dataJSON: Self.dataJSON, signature: nil, keyID: nil)
        let store = tempStore()

        let release = makeClient(body: unsigned, keys: [:], requireSigned: true, storeURL: store)
        #expect(try await release.refresh() == .rejectedUnsigned)
        #expect(release.loadPersisted() == nil) // nothing was ever verified

        let dev = makeClient(body: unsigned, keys: [:], requireSigned: false, storeURL: store)
        #expect(try await dev.refresh() == .updated(entryCount: 2))
    }

    @Test("legacy envelope without `data` grounds nothing and breaks nothing")
    func legacyEnvelope() async throws {
        let legacy = Data("{\"schema_version\":\"0.1.0\",\"issues\":[]}".utf8)
        let client = makeClient(body: legacy, keys: [:], requireSigned: true, storeURL: tempStore())
        #expect(try await client.refresh() == .noCorpusData)
        #expect(client.persistedKnowledgeEntries().isEmpty)
    }

    @Test("safe_action null is semantic: no action offered, tier stays — even over a shipped action")
    func safeActionNullSemantics() async throws {
        // A pulled dasd entry that RETRACTS the shipped safe action.
        let retraction = """
        [{"process_name":"dasd","display_name":"Duet Activity Scheduler",
          "what_it_is":"Apple's background-activity scheduler.",
          "owned_by":"Apple","when_hot_implies":"Under investigation.",
          "safety_tier":3,"safe_action":null,"worst_case":null,
          "causally_linked":[],"sources":[],"platform":"macos","corrected_by":"community-pr-12"}]
        """
        let client = makeClient(
            body: Self.envelope(dataJSON: retraction, signature: nil, keyID: nil),
            keys: [:], requireSigned: false, storeURL: tempStore()
        )
        #expect(try await client.refresh() == .updated(entryCount: 1))
        let merged = client.mergedKnowledgeMap(base: try KnowledgeMap.shipped())
        let dasd = try #require(merged.entry(forProcessName: "dasd"))
        // Shipped dasd had tier 1 + a kill action; the reviewed retraction wins.
        #expect(dasd.safetyTier == 3)
        #expect(dasd.safeAction == nil)
    }

    @Test("non-macOS entries don't match locally")
    func platformFilter() async throws {
        let cross = """
        [{"process_name":"svchost.exe","display_name":"Service Host",
          "what_it_is":"Windows service host.","owned_by":"Microsoft",
          "when_hot_implies":"n/a","safety_tier":3,"safe_action":null,
          "worst_case":null,"causally_linked":[],"sources":[],"platform":"windows","corrected_by":null}]
        """
        let client = makeClient(
            body: Self.envelope(dataJSON: cross, signature: nil, keyID: nil),
            keys: [:], requireSigned: false, storeURL: tempStore()
        )
        #expect(try await client.refresh() == .updated(entryCount: 1))
        #expect(client.persistedKnowledgeEntries().isEmpty)
        #expect(client.persistedKnowledgeEntries(platform: "windows").count == 1)
    }

    @Test("refreshIfStale honors the 24h cadence from the persisted fetch date")
    func staleness() async throws {
        let store = tempStore()
        let client = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: nil, keyID: nil),
            keys: [:], requireSigned: false, storeURL: store
        )
        let epoch = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(try await client.refresh(now: epoch) == .updated(entryCount: 2))
        // 23h later: fresh.
        #expect(try await client.refreshIfStale(hours: 24, now: epoch.addingTimeInterval(23 * 3600)) == .skippedFresh)
        // 25h later: refetches.
        #expect(try await client.refreshIfStale(hours: 24, now: epoch.addingTimeInterval(25 * 3600)) == .updated(entryCount: 2))
    }

    @Test("canonicalization: sorted keys at every depth, compact, slashes and unicode unescaped")
    func canonicalizationShape() throws {
        let bytes = try Self.canonicalData()
        let text = String(decoding: bytes, as: UTF8.self)
        // Keys asciibetical at the top level of each object…
        let dasdRange = try #require(text.range(of: "\"causally_linked\""))
        let displayRange = try #require(text.range(of: "\"display_name\""))
        #expect(dasdRange.lowerBound < displayRange.lowerBound)
        // …compact separators (no whitespace around structural : and ,)…
        #expect(text.contains("\"causally_linked\":[\"appstoreagent\",\"BiomeAgent\"]"))
        #expect(text.contains("\"safety_tier\":1"))
        // …slashes unescaped…
        #expect(text.contains("https://example.com/dasd/analysis"))
        #expect(!text.contains("\\/"))
        // …unicode unescaped…
        #expect(text.contains("émigré"))
        // …null preserved as a bare literal.
        #expect(text.contains("\"safe_action\":null"))
    }

    // MARK: - Disk-cache trust (the store is user-domain, attacker-writable)

    @Test("a valid persisted envelope re-verifies on load — grounding survives offline")
    func persistedEnvelopeVerifiesOnLoad() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.canonicalData()).base64EncodedString()
        let pubkey = key.publicKey.rawRepresentation.base64EncodedString()
        let store = tempStore()

        // Write the verified cache once, over the network.
        let writer = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: signature, keyID: "k1"),
            keys: ["k1": pubkey], storeURL: store
        )
        #expect(try await writer.refresh() == .updated(entryCount: 2))

        // A fresh client with the same pinned key but a transport that THROWS
        // if touched — proves the load path re-verifies from disk alone.
        let offline = CorpusFeedClient(
            baseURL: URL(string: "https://feed.test")!,
            keys: CorpusFeedKeys(keys: ["k1": pubkey]),
            requireSignedFeed: true,
            storeURL: store,
            transport: { _ in throw CorpusFeedClient.FeedError.httpStatus(500) }
        )
        #expect(offline.persistedKnowledgeEntries().count == 2)
    }

    @Test("a tampered persisted cache fails verification on load; the shipped map stands")
    func tamperedPersistedDiscarded() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.canonicalData()).base64EncodedString()
        let pubkey = key.publicKey.rawRepresentation.base64EncodedString()
        let store = tempStore()

        let writer = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: signature, keyID: "k1"),
            keys: ["k1": pubkey], storeURL: store
        )
        #expect(try await writer.refresh() == .updated(entryCount: 2))

        // Poison the on-disk cache: flip a tier under the now-stale signature
        // (the malware-self-whitelist move: mint a kill button / relabel).
        let raw = try String(contentsOf: store, encoding: .utf8)
        let poisoned = raw.replacingOccurrences(of: "\"safety_tier\":3", with: "\"safety_tier\":1")
        #expect(poisoned != raw)
        try poisoned.write(to: store, atomically: true, encoding: .utf8)

        let reader = makeClient(body: Data(), keys: ["k1": pubkey], storeURL: store)
        #expect(reader.persistedKnowledgeEntries().isEmpty) // cache discarded
        // Merge falls back to the shipped map only — no "updated from the fleet".
        let merged = reader.mergedKnowledgeMap(base: try KnowledgeMap.shipped())
        let dasd = try #require(merged.entry(forProcessName: "dasd"))
        #expect(!dasd.whatItIs.contains("updated from the fleet"))
    }

    @Test("a legacy entries-only persisted file (no signature) is discarded on load")
    func legacyPersistedDiscarded() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The OLD persisted shape: fetchedAt + keyID + entries, no data/signature.
        let legacy = """
        {"fetchedAt":"2026-07-05T00:00:00Z","keyID":null,
         "entries":[{"process_name":"evil","display_name":"Evil","what_it_is":"malware posing as Apple",
           "owned_by":"Apple","when_hot_implies":"nothing","safety_tier":3,"safe_action":null,
           "worst_case":null,"causally_linked":[],"platform":"macos","corrected_by":null}]}
        """
        try Data(legacy.utf8).write(to: store)

        let client = makeClient(body: Data(), keys: [:], storeURL: store)
        #expect(client.persistedKnowledgeEntries().isEmpty)
    }

    @Test("an unsigned persisted cache is rejected on load under the release policy")
    func unsignedPersistedRejectedInRelease() async throws {
        let store = tempStore()
        // A dev client legitimately persists an UNSIGNED cache (signature null).
        let dev = makeClient(
            body: Self.envelope(dataJSON: Self.dataJSON, signature: nil, keyID: nil),
            keys: [:], requireSigned: false, storeURL: store
        )
        #expect(try await dev.refresh() == .updated(entryCount: 2))
        #expect(dev.persistedKnowledgeEntries().count == 2) // dev trusts unsigned

        // A RELEASE client pointed at that same unsigned cache rejects it.
        let release = makeClient(body: Data(), keys: [:], requireSigned: true, storeURL: store)
        #expect(release.persistedKnowledgeEntries().isEmpty)
    }

    @Test("floats are outside the canonical domain and refuse to verify")
    func floatsRejected() async throws {
        let floaty = "[{\"process_name\":\"x\",\"weird\":1.5}]"
        let client = makeClient(
            body: Self.envelope(dataJSON: floaty, signature: nil, keyID: nil),
            keys: [:], requireSigned: false, storeURL: tempStore()
        )
        guard case .rejectedBadSignature = try await client.refresh() else {
            Issue.record("float-bearing data was canonicalized — signature bytes would be a guess")
            return
        }
    }
}
