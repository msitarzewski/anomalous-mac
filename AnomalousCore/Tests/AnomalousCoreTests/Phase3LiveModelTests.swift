import Testing
import Foundation
@testable import AnomalousCore

#if canImport(FoundationModels)
import FoundationModels

/// LIVE Foundation Models tests — gated on availability, REAL on Apple
/// Intelligence boxes (maxbeast: contextSize 4096, ~1.25s cold start).
/// Each test degrades to a silent pass on machines without the model.
@Suite("phase 3 live — grounded tool-calling judgment on the real model", .serialized)
struct Phase3LiveModelTests {
    /// The founding busy-poll signature: mysqld hammered by a 1ms-sleep job
    /// queue — ~1400 interrupt wakeups/s against a near-zero flat baseline.
    /// The UNGROUNDED model called this "normal behavior" (memory-bank,
    /// 2026-07-05); these fixtures are the regression fence.
    static func busyPollAnomaly() -> Anomaly {
        Anomaly(
            kind: .energyWakeups,
            identity: ProcessIdentity(pid: 4242, startAbsTime: 7, executableName: "mysqld"),
            windowSeconds: 600,
            magnitudeCurve: [1398, 1400, 1385, 1402],
            baselineValue: 0.2,
            detectedAt: .now,
            drivingMetric: BaselineMetric.wakeupsPerSecond.rawValue,
            baselineDeviation: .infinity,
            confidence: Confidence(score: 0.95),
            alsoObserved: [],
            systemContext: nil
        )
    }

    static func busyPollContext(corpus: [String: KnowledgeEntry]) -> JudgmentContext {
        JudgmentContext(
            processName: "mysqld",
            histories: [
                .init(metric: .wakeupsPerSecond, values: [1398, 1400, 1385, 1402], windowSeconds: 600)
            ],
            baselines: [
                .init(metric: .wakeupsPerSecond, stats: RobustStats(median: 0.2, mad: 0, count: 42), isSeasonal: false, deviation: .infinity)
            ],
            alsoObserved: [],
            correlatedStates: [:],
            corpusEntries: corpus
        )
    }

    static let busyPollBaselineSentence =
        "Normally idles around 0.2 interrupt wakeups per second; for the last 10 minutes it has averaged about 1400 wakeups per second."

    static var modelIsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Test("context budget: instructions + tools + schema + prompt + reserves fit the DYNAMIC contextSize")
    func contextBudgetFits() async throws {
        guard Self.modelIsAvailable else { return }
        guard #available(macOS 26.4, *) else { return }
        let model = SystemLanguageModel.default
        let contextSize = model.contextSize
        #expect(contextSize >= 4096) // this box measured 4096; never assume more

        let map = try KnowledgeMap.shipped()
        let anomaly = Self.busyPollAnomaly()
        let entry = map.entry(forProcessName: "mysqld")
        let context = Self.busyPollContext(corpus: entry.map { ["mysqld": $0] } ?? [:])
        let tools = JudgmentToolbox.tools(for: context)
        let instructions = JudgmentEngine.instructions(
            anomaly: anomaly, entry: entry,
            baselineSentence: Self.busyPollBaselineSentence, toolsAvailable: true
        )

        let cost = try await JudgmentEngine.promptCost(model: model, instructions: instructions, tools: tools)
        let total = cost + JudgmentEngine.responseReserveTokens + JudgmentEngine.toolTrafficReserveTokens
        #expect(
            total <= contextSize,
            "prompt cost \(cost) + reserves exceeds contextSize \(contextSize)"
        )

        // And the trimmer agrees nothing needs to be dropped for this fixture.
        let (fitInstructions, fitTools) = await JudgmentEngine.fitToBudget(
            model: model, instructions: instructions, tools: tools,
            anomaly: anomaly, entry: entry, baselineSentence: Self.busyPollBaselineSentence
        )
        #expect(fitTools.count == tools.count)
        #expect(fitInstructions == instructions)
    }

    @Test("live grounded card quotes the driving-metric number and does NOT call the busy-poll normal")
    func groundedBusyPollCard() async throws {
        guard Self.modelIsAvailable else { return }
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        let anomaly = Self.busyPollAnomaly()
        let entry = map.entry(forProcessName: "mysqld")
        let context = Self.busyPollContext(corpus: entry.map { ["mysqld": $0] } ?? [:])

        let outcome = await engine.judge(anomaly, baselineSentence: Self.busyPollBaselineSentence, context: context)
        guard case .modelCard(let card) = outcome else {
            Issue.record("model available but judge degraded to map-only — inspect the error path")
            return
        }

        // The card must reference the driving metric's number — loose digit
        // match ("1400", tolerating "1,400" / "1.400" grouping re-rolls).
        let allText = [card.whatItIs, card.whyItsProbablyHot, card.isThisNormal, card.confidenceNote]
            .joined(separator: " ")
        let normalized = allText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".400", with: "400")
        #expect(
            normalized.contains("1400") || normalized.contains("1398") || normalized.contains("1402"),
            "card never quotes the ~1400/s figure it was given: \(allText)"
        )

        // THE regression: grounded, this must not come back "normal".
        #expect(
            card.isThisNormalVerdict != DiagnosisCard.NormalVerdict.likelyNormal.rawValue,
            "grounded busy-poll verdict regressed to likely_normal — the ungrounded failure is back"
        )
        #expect(!card.confidenceNote.isEmpty)
        print("[phase3-live] verdict=\(card.isThisNormalVerdict) note=\(card.confidenceNote)")
        print("[phase3-live] isThisNormal=\(card.isThisNormal)")
    }

    @Test("PCC rung probe — exercises rung 2 live and reports what actually happened")
    func pccRungProbe() async throws {
        guard Self.modelIsAvailable else { return }
        guard #available(macOS 27.0, *) else {
            print("[phase3-pcc] macOS 27 API unavailable at runtime — rung 2 not testable here")
            return
        }
        let pcc = PrivateCloudComputeLanguageModel()
        print("[phase3-pcc] availability=\(pcc.availability) isAvailable=\(pcc.isAvailable)")

        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        // An UNKNOWN process → thin grounding → policy selects rung 2.
        let anomaly = Anomaly(
            kind: .energyWakeups,
            identity: ProcessIdentity(pid: 777, startAbsTime: 3, executableName: "zzcustomd"),
            windowSeconds: 600, magnitudeCurve: [900, 910, 905], baselineValue: 0.1,
            detectedAt: .now, drivingMetric: BaselineMetric.wakeupsPerSecond.rawValue,
            baselineDeviation: .infinity, confidence: Confidence(score: 0.6)
        )
        let baseCard = JudgmentEngine.mapOnlyCard(anomaly: anomaly, entry: nil, baselineSentence: "No baseline yet.")
        let outcome = await engine.pccUpgrade(
            anomaly, baselineSentence: "Never seen before; averaging about 905 wakeups per second for 10 minutes.",
            context: JudgmentContext(processName: "zzcustomd"),
            baseCard: baseCard
        )
        switch outcome {
        case .upgraded(let card):
            print("[phase3-pcc] UPGRADED — PCC returned a card: verdict=\(card.isThisNormalVerdict) tier=\(card.actionSafetyTier)")
            #expect(card.actionSafetyTier == 3, "PCC card minted an action for an unknown process")
        case .notAttempted(let why):
            Issue.record("policy/OS gate refused a fixture built to pass it: \(why)")
        case .unavailable(let why):
            print("[phase3-pcc] UNAVAILABLE at runtime (entitlement/eligibility): \(why)")
        case .failed(let why):
            print("[phase3-pcc] FAILED at respond time (degrades silently in product): \(why)")
        case .timedOut:
            print("[phase3-pcc] TIMED OUT after 15s (base card stands — by design)")
        }
        // Whatever rung 2 did, the base card was never blocked on it.
        #expect(baseCard.actionSafetyTier == 3)
    }

    @Test("rung-1 session fallback: unavailable context still yields a card via judge()")
    func noContextStillJudges() async throws {
        guard Self.modelIsAvailable else { return }
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        // No JudgmentContext at all — the pre-Phase-3 single-shot path.
        let outcome = await engine.judge(Self.busyPollAnomaly(), baselineSentence: Self.busyPollBaselineSentence)
        switch outcome {
        case .modelCard(let card), .mapOnlyCard(let card):
            #expect(!card.whatItIs.isEmpty)
        }
    }
}

#endif
