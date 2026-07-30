import Testing
import Foundation
@testable import AnomalousCore

/// Phase 1 (verdict-first cards): the pure, per-machine helpers behind the
/// language-only card — normalization to a believable ceiling, the shape-aware
/// glance, and the verdict derivation with its never-contradict-severity gate.
@Suite("machine-load normalization")
struct MachineLoadTests {
    @Test("per-core CPU divides by the active core count → whole-machine %")
    func perCoreToMachine() {
        // 800% per core (eight fully-pinned cores' worth) on a 10-core machine
        // = 80% of the whole machine.
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 800, cores: 10) == 80)
        // GitHub #2's case: "84% CPU" is ~8.4% of a 10-core Mac, not "almost
        // my whole machine".
        #expect(abs(MachineLoad.machineCPUPercent(perCorePercent: 84, cores: 10) - 8.4) < 0.0001)
    }

    @Test("core count changes the machine share (multi-core)")
    func multiCore() {
        // Same per-core reading is a bigger share of a smaller machine.
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 100, cores: 4) == 25)
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 100, cores: 8) == 12.5)
        // A single full core on a single-core machine = 100%.
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 100, cores: 1) == 100)
    }

    @Test("zero/negative core count degrades to the raw figure, never a divide-by-zero")
    func guardsCores() {
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 150, cores: 0) == 150)
    }

    @Test("whole-machine share is clamped to 0…100 — never over the ceiling")
    func clampsToWholeMachine() {
        // 1500% per core on a 10-core Mac is 150% by raw division — clamp to
        // the believable ceiling, never ">100% of my Mac".
        #expect(MachineLoad.machineCPUPercent(perCorePercent: 1500, cores: 10) == 100)
        #expect(MachineLoad.approxPercent(150) == "about 100%")
    }

    @Test("megabytes normalize to a percent of physical memory")
    func mbToMemory() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        #expect(MachineLoad.memoryPercent(megabytes: 8192, physicalBytes: sixteenGB) == 50)
        #expect(MachineLoad.memoryPercent(megabytes: 4096, physicalBytes: sixteenGB) == 25)
        // A different-sized machine → different share for the same footprint.
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        #expect(MachineLoad.memoryPercent(megabytes: 4096, physicalBytes: eightGB) == 50)
    }

    @Test("zero physical memory is guarded")
    func guardsMemory() {
        #expect(MachineLoad.memoryPercent(megabytes: 1000, physicalBytes: 0) == 0)
    }

    @Test("approxPercent stays calm and never shows a bare 0%")
    func approxPercent() {
        #expect(MachineLoad.approxPercent(35.4) == "about 35%")
        #expect(MachineLoad.approxPercent(0.2) == "less than 1%")
    }
}

@Suite("shape-aware glance sentence")
struct MachineGlanceTests {
    @Test("spike: now far above normal leads with the multiple")
    func spike() {
        let shape = MachineGlance.shape(currentMachinePercent: 35, baselineMachinePercent: 14.5)
        guard case .spike(let multiple) = shape else { Issue.record("expected spike, got \(shape)"); return }
        #expect(abs(multiple - 35.0 / 14.5) < 0.0001)

        let sentence = MachineGlance.sentence(
            resource: .processor, currentMachinePercent: 35,
            baselineMachinePercent: 14.5, duration: "for 3 hours"
        )
        #expect(sentence.contains("your total processing power"))
        #expect(sentence.contains("its usual"))
        #expect(sentence.contains("×"))
        #expect(!sentence.contains("non-stop"))
    }

    @Test("duration: now ≈ normal but sustained leads with the duration")
    func duration() {
        let shape = MachineGlance.shape(currentMachinePercent: 8, baselineMachinePercent: 7)
        #expect(shape == .duration)

        let sentence = MachineGlance.sentence(
            resource: .processor, currentMachinePercent: 8,
            baselineMachinePercent: 7, duration: "for 9 days"
        )
        #expect(sentence.contains("but non-stop for 9 days"))
        #expect(!sentence.contains("×"))
    }

    @Test("a modest low-share process keeps its spike (per-core near-zero, not 0.5% of machine)")
    func lowShareSpikePreserved() {
        // A 4%→40% per-core spike (a real ~10× jump) on a 10-core Mac lives at
        // 0.4%→4% of the WHOLE machine. The old 0.5%-of-machine near-zero guard
        // flattened it to "normally almost none"; a per-core near-zero (1%/core
        // ≈ 0.1% of a 10-core machine) preserves the spike.
        let nearZero = MachineLoad.machineCPUPercent(perCorePercent: 1, cores: 10) // 0.1% of machine
        let shape = MachineGlance.shape(
            currentMachinePercent: 4, baselineMachinePercent: 0.4, nearZeroPercent: nearZero
        )
        guard case .spike(let multiple) = shape else { Issue.record("expected spike, got \(shape)"); return }
        #expect(abs(multiple - 10) < 0.0001)
    }

    @Test("memory in the duration shape is never 'non-stop' (a level, not activity)")
    func memoryNeverNonStop() {
        // com.apple.Virtualization at 20% memory, baseline 15% → duration shape.
        let shape = MachineGlance.shape(currentMachinePercent: 20, baselineMachinePercent: 15)
        #expect(shape == .duration)

        let sentence = MachineGlance.sentence(
            resource: .memory, currentMachinePercent: 20,
            baselineMachinePercent: 15, duration: "for 1 second"
        )
        #expect(sentence.contains("your memory"))
        #expect(!sentence.contains("non-stop"))     // memory is a level, not "non-stop"
        #expect(!sentence.contains("for 1 second"))  // never cite a trivial duration
        #expect(sentence.contains("a little more than usual"))
    }

    @Test("a fresh CPU flag never says 'non-stop for 1 second' — just 'above its usual'")
    func freshDurationIsNotCited() {
        let sentence = MachineGlance.sentence(
            resource: .processor, currentMachinePercent: 8,
            baselineMachinePercent: 7, duration: "for 1 second",
            durationIsMeaningful: false
        )
        #expect(!sentence.contains("non-stop"))
        #expect(!sentence.contains("for 1 second"))
        #expect(sentence.contains("above its usual"))
    }

    @Test("near-zero baseline drops the meaningless multiple")
    func nearZeroBaseline() {
        let shape = MachineGlance.shape(currentMachinePercent: 40, baselineMachinePercent: 0.1)
        #expect(shape == .nearZeroBaseline)

        let sentence = MachineGlance.sentence(
            resource: .memory, currentMachinePercent: 40,
            baselineMachinePercent: 0.1, duration: "for 2 hours"
        )
        #expect(sentence.contains("your memory"))
        #expect(sentence.contains("normally almost none"))
        #expect(!sentence.contains("×"))
    }
}

@Suite("verdict derivation + never-contradict-severity gate")
struct VerdictDerivationTests {
    private let normal = DiagnosisCard.NormalVerdict.likelyNormal.rawValue
    private let uncertain = DiagnosisCard.NormalVerdict.uncertain.rawValue
    private let abnormal = DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue
    private let high = Confidence(score: 0.9)
    private let low = Confidence(score: 0.3)

    @Test("the three canonical verdicts map through")
    func canonical() {
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: normal, actionSafetyTier: 1, confidence: high) == "This looks fine")
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: uncertain, actionSafetyTier: 1, confidence: high) == "Worth a look")
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: abnormal, actionSafetyTier: 2, confidence: high) == "This needs a look")
    }

    @Test("GATE: a never-normal-when-hot process (tier ≥ 3) can never be told it looks fine")
    func severityGate() {
        // A tier-3 process (a database, kernel_task, an unknown) read as
        // likely_normal must NOT get "This looks fine" — the corpus says a hot
        // one is never routine.
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: normal, actionSafetyTier: 3, confidence: high) == "Worth a look")
    }

    @Test("thin evidence never earns full reassurance")
    func lowConfidenceNormal() {
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: normal, actionSafetyTier: 1, confidence: low) == "Worth a look")
    }

    @Test("a low-confidence abnormal call softens rather than shouts")
    func lowConfidenceAbnormal() {
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: abnormal, actionSafetyTier: 2, confidence: low) == "Worth a look")
        // High confidence keeps the firm wording.
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: abnormal, actionSafetyTier: 3, confidence: high) == "This needs a look")
    }

    @Test("an unknown verdict string degrades to the cautious middle")
    func unknownDegrades() {
        #expect(DiagnosisCard.deriveVerdict(isThisNormalVerdict: "garbage", actionSafetyTier: 1, confidence: high) == "Worth a look")
    }

    @Test("INVARIANT: a destructive button can never sit beside a reassuring headline")
    func destructiveActionForbidsReassurance() {
        // The self-contradictory server response the guard used to miss:
        // likely_normal + a destructive Quit/Restart. The headline must refuse
        // "This looks fine" and soften to "Worth a look".
        #expect(
            DiagnosisCard.deriveVerdict(
                isThisNormalVerdict: normal, actionSafetyTier: 1,
                confidence: high, offeredActionIsDestructive: true
            ) == DiagnosisCard.Verdict.worthALook
        )
        // Exhaustive: across every verdict / tier / confidence, a destructive
        // action never yields the reassuring headline — the contradiction can
        // no longer render.
        for raw in [normal, uncertain, abnormal, "garbage"] {
            for tier in 1...3 {
                for confidence in [high, low] {
                    let headline = DiagnosisCard.deriveVerdict(
                        isThisNormalVerdict: raw, actionSafetyTier: tier,
                        confidence: confidence, offeredActionIsDestructive: true
                    )
                    #expect(headline != DiagnosisCard.Verdict.looksFine)
                }
            }
        }
        // A non-destructive offer leaves the reassuring path intact.
        #expect(
            DiagnosisCard.deriveVerdict(
                isThisNormalVerdict: normal, actionSafetyTier: 1,
                confidence: high, offeredActionIsDestructive: false
            ) == DiagnosisCard.Verdict.looksFine
        )
    }
}

@Suite("action never argues with the prose (Quit-contradiction)")
struct VerdictActionReconcileTests {
    private let normal = DiagnosisCard.NormalVerdict.likelyNormal.rawValue
    private let abnormal = DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue

    @Test("a destructive offer is demoted when the card says this looks fine")
    func demotesOnLooksFine() {
        let reconciled = ProcessAction.reconciledWithVerdict(
            .terminate, isThisNormalVerdict: normal, serverRequestedDestructive: false
        )
        #expect(reconciled == .explainOnly)
    }

    @Test("an explicit server quit is respected even on a fine-looking card")
    func serverQuitWins() {
        let reconciled = ProcessAction.reconciledWithVerdict(
            .terminate, isThisNormalVerdict: normal, serverRequestedDestructive: true
        )
        #expect(reconciled == .terminate)
    }

    @Test("a genuinely abnormal card keeps its actionable button")
    func abnormalKeepsButton() {
        let reconciled = ProcessAction.reconciledWithVerdict(
            .restartApp, isThisNormalVerdict: abnormal, serverRequestedDestructive: false
        )
        #expect(reconciled == .restartApp)
    }

    @Test("a non-destructive action is left untouched")
    func nonDestructiveUntouched() {
        #expect(ProcessAction.reconciledWithVerdict(.update, isThisNormalVerdict: normal, serverRequestedDestructive: false) == .update)
        #expect(ProcessAction.reconciledWithVerdict(.explainOnly, isThisNormalVerdict: normal, serverRequestedDestructive: false) == .explainOnly)
    }
}

/// The exception-based urgency cue: the title-row badge is driven by MAGNITUDE,
/// not by the model's normal/abnormal verdict, and stays SILENT in the common
/// case (a mild elevation, or a normal-looking card). These pin the classifier's
/// ordered rules and the named, tunable magnitude bars.
@Suite("urgency cue classifier")
struct UrgencyCueTests {
    /// A convenience over `classify` with the "quiet, confident, ordinary app"
    /// defaults, so each test overrides only the axis it exercises.
    private func classify(
        ratio: Double? = nil,
        share: Double? = nil,
        verdict: DiagnosisCard.NormalVerdict = .likelyAbnormal,
        tier: Int = 3,
        lowConfidence: Bool = false,
        isFrozenApp: Bool = false,
        isThermal: Bool = false,
        isGenuinelyUnknown: Bool = false
    ) -> UrgencyCue {
        UrgencyCue.classify(
            ratioAboveNormal: ratio, resourceSharePercent: share, verdict: verdict,
            tier: tier, lowConfidence: lowConfidence, isFrozenApp: isFrozenApp,
            isThermal: isThermal, isGenuinelyUnknown: isGenuinelyUnknown
        )
    }

    @Test("a mild ratio elevation stays quiet — no badge")
    func mildRatioIsNone() {
        // 1.6× baseline, a modest 15% of the machine — below every bar.
        #expect(classify(ratio: 1.6, share: 15) == .none)
    }

    @Test("the '20% memory, ~1.3× baseline' coherence case → none")
    func coherentModerateMemoryIsNone() {
        // com.apple.Virtualization at ~20% of memory, ~1.3× its own usual: the
        // observation reads "a little more than usual", so the badge must agree.
        #expect(classify(ratio: 1.3, share: 20, tier: 2) == .none)
    }

    @Test("a notable spike → worth a look (amber)")
    func notableSpikeIsWorthALook() {
        // 3× baseline clears mildRatioCeiling but not extremeRatio → amber.
        #expect(classify(ratio: 3.0, share: 40, tier: 2) == .worthALook)
        // A big share alone (65% of the machine) is notable on its own.
        #expect(classify(ratio: 1.2, share: 65, tier: 2) == .worthALook)
    }

    @Test("extreme + KNOWN tier 3 + confident → needs a look (red)")
    func extremeTierThreeConfidentIsNeedsALook() {
        // A corpus-KNOWN never-normal-when-hot process (e.g. a database) at
        // extreme magnitude is the one population red is for.
        #expect(classify(ratio: 8.0, share: 40, tier: 3, lowConfidence: false,
                         isGenuinelyUnknown: false) == .needsALook)
        // Extreme by SHARE (95% of a resource) qualifies too.
        #expect(classify(ratio: 2.0, share: 95, tier: 4, isGenuinelyUnknown: false) == .needsALook)
    }

    @Test("extreme but genuinely UNKNOWN → at most amber, never red")
    func extremeUnknownTierThreeIsWorthALook() {
        // An unfamiliar system process (coreaudiod, a Vision Pro sim) defaults to
        // tier 3 only because the corpus doesn't recognize it — "we don't know it"
        // is worth a look, not an alarm. However extreme, it tops out at amber.
        #expect(classify(ratio: 8.0, share: 40, tier: 3, lowConfidence: false,
                         isGenuinelyUnknown: true) == .worthALook)
        #expect(classify(ratio: 2.0, share: 95, tier: 4, isGenuinelyUnknown: true) == .worthALook)
    }

    @Test("extreme but tier < 3 → at most amber (a GPU sim / WindowServer)")
    func extremeButLowTierIsWorthALook() {
        #expect(classify(ratio: 10.0, share: 99, tier: 2) == .worthALook)
    }

    @Test("extreme but low confidence never earns red")
    func extremeLowConfidenceIsWorthALook() {
        #expect(classify(ratio: 8.0, share: 95, tier: 3, lowConfidence: true) == .worthALook)
    }

    @Test("a likely-normal verdict is always quiet")
    func likelyNormalIsNone() {
        // Even an extreme magnitude: the model read it as routine for this
        // process, so the card existing is enough.
        #expect(classify(ratio: 10.0, share: 99, verdict: .likelyNormal, tier: 3) == .none)
    }

    @Test("a metric with no baseline falls back to the model's read")
    func noBaselineFallsBackToVerdict() {
        // fileproviderd cputime-ratio: no ratio, no share. likely_abnormal is
        // notable (amber); uncertain is not (quiet).
        #expect(classify(ratio: nil, share: nil, verdict: .likelyAbnormal, tier: 3) == .worthALook)
        #expect(classify(ratio: nil, share: nil, verdict: .uncertain, tier: 3) == .none)
    }

    @Test("a frozen app is a caution — worth a look, never an emergency")
    func frozenAppIsWorthALook() {
        // Overrides magnitude and verdict: a hung app has ~0 CPU / flat memory.
        #expect(classify(ratio: nil, share: nil, verdict: .likelyNormal, isFrozenApp: true) == .worthALook)
    }

    @Test("a thermal card is the one genuine emergency → needs a look")
    func thermalIsNeedsALook() {
        // kernel_task thermal wins over everything, even a low tier / low confidence.
        #expect(classify(ratio: 1.0, share: 5, tier: 1, lowConfidence: true, isThermal: true) == .needsALook)
    }
}
