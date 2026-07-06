import Testing
import Foundation
@testable import AnomalousCore

@Suite("diagnosis card — cache back-compat across the Phase-3 additive fields")
struct DiagnosisCardCompatTests {
    /// A cached diagnosis exactly as v1 wrote it — six card fields, no
    /// verdict, no confidence note. MUST keep loading.
    static let v1JSON = """
    {"whatItIs":"Apple's background-activity scheduler.",
     "whyItsProbablyHot":"Almost always a wedged scheduling loop.",
     "isThisNormal":"Normally about 0.1% CPU; now around 150% for 41 hours.",
     "suggestedAction":"kill — launchd respawns it",
     "actionSafetyTier":1,
     "causallyLinkedProcesses":["appstoreagent"],
     "anomalyKind":"cputime_ratio",
     "judgedByModel":true}
    """

    @Test("v1 cached diagnosis JSON decodes; additive fields default honestly")
    func v1Decodes() throws {
        let cached = try JSONDecoder().decode(CachedDiagnosis.self, from: Data(Self.v1JSON.utf8))
        #expect(cached.whatItIs == "Apple's background-activity scheduler.")
        #expect(cached.actionSafetyTier == 1)
        #expect(cached.causallyLinkedProcesses == ["appstoreagent"])
        #expect(cached.judgedByModel)
        // Additive defaults: an old card never claims a verdict it didn't make.
        #expect(cached.isThisNormalVerdict == "uncertain")
        #expect(cached.confidenceNote.isEmpty)
        // Reconstructed card carries the defaults through.
        let card = cached.card
        #expect(card.isThisNormalVerdict == "uncertain")
        #expect(card.suggestedAction == "kill — launchd respawns it")
    }

    @Test("v2 cache round-trips the verdict and confidence note")
    func v2RoundTrip() throws {
        let card = DiagnosisCard(
            whatItIs: "w", whyItsProbablyHot: "h", isThisNormal: "n",
            suggestedAction: "a", actionSafetyTier: 2, causallyLinkedProcesses: [],
            isThisNormalVerdict: "likely_abnormal",
            confidenceNote: "High confidence: two independent signals agree."
        )
        let cached = CachedDiagnosis(card: card, kind: .energyWakeups, judgedByModel: true)
        let decoded = try JSONDecoder().decode(CachedDiagnosis.self, from: JSONEncoder().encode(cached))
        #expect(decoded.isThisNormalVerdict == "likely_abnormal")
        #expect(decoded.confidenceNote == "High confidence: two independent signals agree.")
        #expect(decoded.anomalyKind == "energy.wakeups")
    }

    @Test("six-field init stays byte-compatible and defaults the new fields")
    func v1InitCompat() {
        let card = DiagnosisCard(
            whatItIs: "w", whyItsProbablyHot: "h", isThisNormal: "n",
            suggestedAction: "a", actionSafetyTier: 3, causallyLinkedProcesses: ["x"]
        )
        #expect(card.whatItIs == "w")
        #expect(card.actionSafetyTier == 3)
        #expect(card.isThisNormalVerdict == DiagnosisCard.NormalVerdict.uncertain.rawValue)
        #expect(card.confidenceNote.isEmpty)
    }

    @Test("deterministic cards carry honest verdicts without touching the six v1 fields")
    func deterministicCardVerdicts() {
        let anomaly = Anomaly(
            kind: .appHung,
            identity: ProcessIdentity(pid: 9, startAbsTime: 1, executableName: "Safari"),
            windowSeconds: 120, magnitudeCurve: [120], baselineValue: nil, detectedAt: .now
        )
        let hung = JudgmentEngine.hungAppCard(anomaly: anomaly, baselineSentence: "n/a")
        #expect(hung.isThisNormalVerdict == "likely_abnormal")
        #expect(hung.suggestedAction == "Force quit and relaunch it.")
        #expect(hung.actionSafetyTier == 2)

        let mapOnly = JudgmentEngine.mapOnlyCard(anomaly: anomaly, entry: nil, baselineSentence: "No baseline yet.")
        #expect(mapOnly.isThisNormalVerdict == "uncertain")
        #expect(mapOnly.confidenceNote.contains("high")) // legacy default confidence quotes its level
        #expect(mapOnly.actionSafetyTier == 3)
    }
}
