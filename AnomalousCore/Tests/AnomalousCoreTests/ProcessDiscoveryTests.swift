import Testing
import Foundation
@testable import AnomalousCore

// MARK: - #1 On-device routing: the unknown-process gate

@Suite("on-device gate — a bundle names the app; a mystery daemon does not")
struct JudgmentRouteTests {
    private func anomaly(
        name: String,
        bundleID: String? = nil,
        appVersion: String? = nil,
        kind: Anomaly.Kind = .sustainedCPU
    ) -> Anomaly {
        Anomaly(
            kind: kind,
            identity: ProcessIdentity(
                pid: 7, startAbsTime: 1, executableName: name,
                bundleID: bundleID, appVersion: appVersion
            ),
            windowSeconds: 1800, magnitudeCurve: [150, 151], baselineValue: 0.5, detectedAt: .now
        )
    }

    @Test("bundle-identified unknown → the MODEL is consulted (anchored on the app), not the deterministic card")
    func bundleUnknownRoutesToModel() {
        let a = anomaly(name: "Google Chrome Helper", bundleID: "com.google.Chrome.helper")
        #expect(JudgmentEngine.route(for: a, hasCorpusEntry: false) == .model)
    }

    @Test("no bundle + not in corpus → the conservative deterministic unknown card (the model never guesses)")
    func mysteryDaemonRoutesToDeterministic() {
        let a = anomaly(name: "xz7q1dr", bundleID: nil)
        #expect(JudgmentEngine.route(for: a, hasCorpusEntry: false) == .deterministicUnknown)
    }

    @Test("in-corpus process → model path even with no bundle (a known daemon like dasd)")
    func knownDaemonRoutesToModel() {
        let a = anomaly(name: "dasd", bundleID: nil)
        #expect(JudgmentEngine.route(for: a, hasCorpusEntry: true) == .model)
    }

    @Test("kernel_task and hung apps keep their deterministic special-cases")
    func specialCasesUnchanged() {
        #expect(JudgmentEngine.route(for: anomaly(name: "kernel_task"), hasCorpusEntry: false) == .thermal)
        #expect(JudgmentEngine.route(for: anomaly(name: "Notes", bundleID: "com.apple.Notes", kind: .appHung), hasCorpusEntry: false) == .hungApp)
    }

    @Test("instructions anchor an unknown-but-bundled app on its bundle id, and never call it a nameless mystery")
    func bundleAnchoredInstructions() {
        let a = anomaly(name: "Google Chrome Helper", bundleID: "com.google.Chrome.helper", appVersion: "141.0")
        let text = JudgmentEngine.instructions(anomaly: a, entry: nil, baselineSentence: "b")
        #expect(text.contains("com.google.Chrome.helper"))
        #expect(text.contains("known application"))
        #expect(text.contains("141.0"))
        #expect(!text.contains("no app identity"))
    }

    @Test("instructions stay conservative for a genuinely nameless process")
    func mysteryInstructions() {
        let text = JudgmentEngine.instructions(anomaly: anomaly(name: "xz7q1dr"), entry: nil, baselineSentence: "b")
        #expect(text.contains("UNKNOWN process"))
        #expect(text.contains("Safety tier must be 3"))
    }
}

// MARK: - #2 Discovery client: compose, encode, decode, map, send-log

@Suite("discovery client — anonymous lookup for genuinely-unknown processes")
struct DiscoveryClientTests {
    private func anomaly(name: String, bundleID: String? = nil, source: InstallSource = .other) -> Anomaly {
        Anomaly(
            kind: .energyWakeups,
            identity: ProcessIdentity(
                pid: 9, startAbsTime: 2, executableName: name,
                bundleID: bundleID, appVersion: bundleID == nil ? nil : "1.2", installSource: source
            ),
            windowSeconds: 600, magnitudeCurve: [1400, 1402], baselineValue: 0.2, detectedAt: .now,
            drivingMetric: BaselineMetric.wakeupsPerSecond.rawValue
        )
    }

    @Test("request composes only anonymous, snake_cased fields — no path/user possible")
    func composeEncodesAnonymously() throws {
        let req = DiscoveryClient.compose(anomaly: anomaly(name: "weird_helper", bundleID: "com.acme.helper", source: .homebrew), osVersion: "27.1")
        let raw = String(decoding: try DiscoveryClient.encode(req), as: UTF8.self)
        #expect(raw.contains("\"name\":\"weird_helper\""))
        #expect(raw.contains("\"bundle_id\":\"com.acme.helper\""))
        #expect(raw.contains("\"os_version\":\"27.1\""))
        #expect(raw.contains("\"install_source\":\"homebrew\""))
        #expect(raw.contains("\"anomaly_type\":\"energy.wakeups\""))
        #expect(raw.contains("\"schema_version\":\"0.1.0\""))
        // Structural anonymity — the type has no field for these.
        #expect(!raw.contains(NSUserName()))
        #expect(!raw.contains("/Users/"))
    }

    @Test("an .other install source carries no signal and is omitted from the request")
    func otherInstallSourceOmitted() throws {
        let req = DiscoveryClient.compose(anomaly: anomaly(name: "xz7q1dr"), osVersion: "27.1")
        #expect(req.installSource == nil)
        let raw = String(decoding: try DiscoveryClient.encode(req), as: UTF8.self)
        #expect(!raw.contains("install_source"))
    }

    @Test("202 accepted decodes to a discovery id to poll, no assessment yet")
    func decode202Accepted() throws {
        let data = Data(#"{"discovery_id":"disc_abc","status":"researching"}"#.utf8)
        let sub = try DiscoveryClient.decodeSubmission(data)
        #expect(sub.discoveryID == "disc_abc")
        #expect(sub.status == .researching)
        #expect(sub.assessment == nil)
    }

    @Test("200 cache-hit decodes to a complete assessment inline")
    func decode200CacheHit() throws {
        let json = #"""
        {"status":"complete","assessment":{"what_it_is":"A Chrome renderer helper.","why_hot":"A busy tab.","is_this_normal":"Sometimes.","suggested_action":"Close the tab.","safety_tier":2,"sources":[{"url":"https://example.com","note":"Chrome docs"}],"source":"anomalous","verified":true}}
        """#
        let sub = try DiscoveryClient.decodeSubmission(Data(json.utf8))
        #expect(sub.status == .complete)
        let a = try #require(sub.assessment)
        #expect(a.whatItIs == "A Chrome renderer helper.")
        #expect(a.safetyTier == 2)
        #expect(a.verified)
        #expect(a.isSourcedByAnomalous)
        #expect(a.sources.first?.url == "https://example.com")
    }

    @Test("poll decodes complete / unknown honestly")
    func decodePollStates() throws {
        let complete = try DiscoveryClient.decodePoll(Data(#"{"status":"complete","assessment":{"what_it_is":"x","is_this_normal":"y","safety_tier":3,"source":"anomalous","verified":false}}"#.utf8))
        #expect(complete.status == .complete)
        #expect(complete.assessment?.suggestedAction == nil)   // absent optional decodes to nil
        let unknown = try DiscoveryClient.decodePoll(Data(#"{"status":"unknown"}"#.utf8))
        #expect(unknown.status == .unknown)
        #expect(unknown.assessment == nil)
    }

    @Test("a complete assessment maps into a DiagnosisCard, keeping the detector's baseline sentence and the Anomalous attribution")
    func assessmentMapsToCard() {
        let a = DiscoveryClient.Assessment(
            whatItIs: "A Chrome renderer helper process.",
            whyHot: "One of your tabs is doing heavy work.",
            isThisNormal: "Common for an active browser.",
            suggestedAction: "Close the heavy tab.",
            safetyTier: 2,
            sources: [.init(url: "https://example.com", note: "vendor docs")],
            source: "anomalous",
            verified: true
        )
        let card = a.card(baselineSentence: "Normally ~0.2 wakeups/s; now ~1400 wakeups/s.")
        #expect(card.whatItIs == "A Chrome renderer helper process.")
        #expect(card.isThisNormal == "Normally ~0.2 wakeups/s; now ~1400 wakeups/s.")   // detector fact preserved
        #expect(card.suggestedAction == "Close the heavy tab.")
        #expect(card.actionSafetyTier == 2)
        #expect(card.whyItsProbablyHot.contains("heavy work"))
        #expect(card.confidenceNote.contains("Sourced by Anomalous"))
        #expect(card.isThisNormalVerdict == DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue)  // tier < 3
    }

    @Test("discovery client logs the exact bytes to the send log BEFORE sending — flow .discovery")
    func logsBeforeSend() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "disc-test-\(UUID().uuidString)")
        let log = SendLog(directory: dir)
        let client = DiscoveryClient(baseURL: URL(string: "http://127.0.0.1:1")!, sendLog: log)
        let req = DiscoveryClient.compose(anomaly: anomaly(name: "xz7q1dr"), osVersion: "27.1")
        // Port 1 refuses the connection, but the send log must already hold the
        // exact request bytes — auditable beats approvable.
        _ = try? await client.discover(req)
        let entries = await log.all()
        #expect(entries.count == 1)
        #expect(entries.first?.flow == .discovery)
        #expect(entries.first?.payload == (try DiscoveryClient.encode(req)))
    }
}
