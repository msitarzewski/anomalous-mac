import Testing
import Foundation
@testable import AnomalousCore

// The inverse rule: a "Not Responding" app. ~0 CPU, flat memory, so none of the
// over-use rules fire — hungAppAnomaly is driven by an externally-tracked
// unresponsive duration (the window-server's liveness flag), not by samples.

private func app(_ name: String = "Notes", bundleID: String? = "com.apple.Notes") -> ProcessIdentity {
    ProcessIdentity(pid: 501, startAbsTime: 7, executableName: name, bundleID: bundleID)
}

@Suite("hung app — the inverse of a runaway")
struct HungAppRuleTests {
    @Test("fires exactly at the threshold")
    func firesAtThreshold() {
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app(), unresponsiveSeconds: 25, threshold: 25,
            magnitudeCurve: [25], detectedAt: .now
        )
        #expect(anomaly?.kind == .appHung)
    }

    @Test("fires well past the threshold")
    func firesPastThreshold() {
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app(), unresponsiveSeconds: 3 * 60, threshold: 25,
            magnitudeCurve: [180], detectedAt: .now
        )
        #expect(anomaly?.kind == .appHung)
        #expect(anomaly?.windowSeconds == 180)
    }

    @Test("stays silent below the threshold")
    func silentBelowThreshold() {
        #expect(DetectionRules.hungAppAnomaly(
            identity: app(), unresponsiveSeconds: 10, threshold: 25,
            magnitudeCurve: [10], detectedAt: .now
        ) == nil)
    }

    @Test("carries the app identity through to the anomaly")
    func carriesIdentity() {
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app("Xcode", bundleID: "com.apple.dt.Xcode"),
            unresponsiveSeconds: 40, threshold: 25, magnitudeCurve: [40], detectedAt: .now
        )
        #expect(anomaly?.identity.bundleID == "com.apple.dt.Xcode")
        #expect(anomaly?.baselineValue == nil)
    }
}

@Suite("hung app — deterministic force-quit card")
struct HungAppCardTests {
    @Test("appHung judged as a map-only card: tier 2, mentions unresponsive + force quit")
    func hungAppCard() async throws {
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app("Notes"), unresponsiveSeconds: 120, threshold: 25,
            magnitudeCurve: [120], detectedAt: .now
        )!
        let outcome = await engine.judge(anomaly, baselineSentence: "This app is normally responsive.")
        guard case .mapOnlyCard(let card) = outcome else {
            Issue.record("expected a map-only hung-app card"); return
        }
        #expect(card.actionSafetyTier == 2)
        #expect(card.whatItIs.contains("Notes"))
        #expect(card.whatItIs.lowercased().contains("unresponsive"))
        #expect(card.suggestedAction.lowercased().contains("force quit"))
    }

    @Test("card reports the duration in minutes, pluralised")
    func cardReportsMinutes() {
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app("Mail"), unresponsiveSeconds: 120, threshold: 25,
            magnitudeCurve: [120], detectedAt: .now
        )!
        let card = JudgmentEngine.hungAppCard(anomaly: anomaly, baselineSentence: "n/a")
        #expect(card.whatItIs.contains("2 minutes"))
    }

    @Test("a hung app never routes through the LLM path — always deterministic")
    func alwaysDeterministic() async throws {
        // The judge() early branch returns mapOnlyCard for .appHung regardless of
        // model availability, so the card is stable and instant.
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        let anomaly = DetectionRules.hungAppAnomaly(
            identity: app("Safari", bundleID: "com.apple.Safari"),
            unresponsiveSeconds: 30, threshold: 25, magnitudeCurve: [30], detectedAt: .now
        )!
        guard case .mapOnlyCard = await engine.judge(anomaly, baselineSentence: "n/a") else {
            Issue.record("appHung must never yield a modelCard"); return
        }
    }
}
