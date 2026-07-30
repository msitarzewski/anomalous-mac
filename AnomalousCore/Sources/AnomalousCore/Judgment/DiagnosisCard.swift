import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// The diagnosis card — the product's voice. One schema, three rungs:
/// on-device SystemLanguageModel, Private Cloud Compute, and the Anomalous
/// triage backend (a custom LanguageModel provider, WWDC26 s339) all fill
/// THIS type. Cards degrade honestly: evidence fields stay empty unless a
/// tool returned them — hallucinated specificity is worse than honest
/// vagueness (projectRules.md #3).
@Generable
public struct DiagnosisCard: Sendable {
    /// The explicit machine-readable verdict vocabulary for
    /// `isThisNormalVerdict` — mirrors the @Guide anyOf list below.
    public enum NormalVerdict: String, Sendable, CaseIterable {
        case likelyNormal = "likely_normal"
        case uncertain = "uncertain"
        case likelyAbnormal = "likely_abnormal"
    }

    @Guide(description: "What this process is and does — thorough but plain, 1-2 sentences a non-technical person understands. Keep the useful detail; ground it in the knowledge-map entry; never invent identity.")
    public var whatItIs: String

    @Guide(description: "In plain, non-technical English, what is most likely happening and why — the 'what this means' that helps an ordinary person understand the situation. Lead with the plain situation, not raw figures: describe the behaviour in words (e.g. 'It's stuck retrying a background task') rather than quoting exact CPU/memory numbers — the app shows those separately in Details. One or two short sentences, grounded in the knowledge map's whenHotImplies. No jargon.")
    public var whyItsProbablyHot: String

    @Guide(description: "One short, calm sentence on whether this is normal for this process and roughly how far from normal it is, in plain words ('far above what's usual for it', 'a little higher than usual'). Do NOT quote exact percentages, megabytes, or minute-counts here — the app renders the precise figures in Details. No rule names.")
    public var isThisNormal: String

    @Guide(description: "The recommended action as a verb phrase (e.g. 'Update Chrome', 'Restart the app', 'Safe to kill — launchd respawns it'). The safest immediate action if no specific fix is known.")
    public var suggestedAction: String

    @Guide(description: "Safety tier of the suggested action: 1 = one-click safe, 2 = warn first, 3 = explain only, no button. When uncertain, choose 3.")
    public var actionSafetyTier: Int

    @Guide(description: "Process names causally linked to this anomaly, from the knowledge map's causallyLinked field only. Empty if none.")
    public var causallyLinkedProcesses: [String]

    @Guide(description: "The machine verdict on whether this behavior is normal for this process. The detector already judged it abnormal; answer likely_normal ONLY if the provided facts (baseline, seasonality, system context) genuinely explain the behavior as routine.", .anyOf(["likely_normal", "uncertain", "likely_abnormal"]))
    public var isThisNormalVerdict: String

    @Guide(description: "One short sentence on how sure this diagnosis is and what it rests on, quoting the detector's confidence you were given (e.g. 'High confidence: two independent signals agree and the rate is far above its recorded baseline').")
    public var confidenceNote: String

    /// The plain-English headline verdict shown as the card's focal line
    /// ("This looks fine" / "Worth a look" / "This needs a look"). Derived
    /// CLIENT-SIDE from `isThisNormalVerdict` + `actionSafetyTier` + confidence
    /// (see `deriveVerdict`) — per-machine, so it never belonged in the shared
    /// corpus. Additive: cached v1/v2 cards decode it as "" and the view
    /// derives on the fly.
    @Guide(description: "Always output an empty string here. The app writes the plain-English verdict headline itself from the detector's judgment; do not compose one.")
    public var verdict: String

    /// v1 six-field init, byte-compatible for cache/back-compat — cached v1
    /// diagnoses reconstruct through this and get honest defaults for the
    /// additive Phase-3 fields.
    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String]) {
        self.init(
            whatItIs: whatItIs, whyItsProbablyHot: whyItsProbablyHot, isThisNormal: isThisNormal,
            suggestedAction: suggestedAction, actionSafetyTier: actionSafetyTier,
            causallyLinkedProcesses: causallyLinkedProcesses,
            isThisNormalVerdict: NormalVerdict.uncertain.rawValue, confidenceNote: ""
        )
    }

    /// Full init (the @Generable macro doesn't expose a public memberwise init).
    /// `verdict` defaults to "" so every existing caller keeps compiling; it's
    /// set client-side once the derivation inputs are known.
    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String], isThisNormalVerdict: String, confidenceNote: String, verdict: String = "") {
        self.whatItIs = whatItIs
        self.whyItsProbablyHot = whyItsProbablyHot
        self.isThisNormal = isThisNormal
        self.suggestedAction = suggestedAction
        self.actionSafetyTier = actionSafetyTier
        self.causallyLinkedProcesses = causallyLinkedProcesses
        self.isThisNormalVerdict = isThisNormalVerdict
        self.confidenceNote = confidenceNote
        self.verdict = verdict
    }
}

#else

/// Fallback definition for toolchains without FoundationModels — same
/// shape, no guided generation. Filled from the knowledge map only.
public struct DiagnosisCard: Sendable, Codable {
    public enum NormalVerdict: String, Sendable, CaseIterable {
        case likelyNormal = "likely_normal"
        case uncertain = "uncertain"
        case likelyAbnormal = "likely_abnormal"
    }

    public var whatItIs: String
    public var whyItsProbablyHot: String
    public var isThisNormal: String
    public var suggestedAction: String
    public var actionSafetyTier: Int
    public var causallyLinkedProcesses: [String]
    public var isThisNormalVerdict: String
    public var confidenceNote: String
    /// Plain-English headline verdict, derived client-side (see `deriveVerdict`).
    public var verdict: String

    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String]) {
        self.init(
            whatItIs: whatItIs, whyItsProbablyHot: whyItsProbablyHot, isThisNormal: isThisNormal,
            suggestedAction: suggestedAction, actionSafetyTier: actionSafetyTier,
            causallyLinkedProcesses: causallyLinkedProcesses,
            isThisNormalVerdict: NormalVerdict.uncertain.rawValue, confidenceNote: ""
        )
    }

    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String], isThisNormalVerdict: String, confidenceNote: String, verdict: String = "") {
        self.whatItIs = whatItIs
        self.whyItsProbablyHot = whyItsProbablyHot
        self.isThisNormal = isThisNormal
        self.suggestedAction = suggestedAction
        self.actionSafetyTier = actionSafetyTier
        self.causallyLinkedProcesses = causallyLinkedProcesses
        self.isThisNormalVerdict = isThisNormalVerdict
        self.confidenceNote = confidenceNote
        self.verdict = verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whatItIs = try c.decode(String.self, forKey: .whatItIs)
        whyItsProbablyHot = try c.decode(String.self, forKey: .whyItsProbablyHot)
        isThisNormal = try c.decode(String.self, forKey: .isThisNormal)
        suggestedAction = try c.decode(String.self, forKey: .suggestedAction)
        actionSafetyTier = try c.decode(Int.self, forKey: .actionSafetyTier)
        causallyLinkedProcesses = try c.decode([String].self, forKey: .causallyLinkedProcesses)
        isThisNormalVerdict = try c.decodeIfPresent(String.self, forKey: .isThisNormalVerdict) ?? NormalVerdict.uncertain.rawValue
        confidenceNote = try c.decodeIfPresent(String.self, forKey: .confidenceNote) ?? ""
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
    }
}

#endif

/// A Codable snapshot of a DiagnosisCard for persistence. Caching the card
/// (keyed per flagged process) means the SAME answer shows every time a
/// condition recurs — stable phrasing, no repeated on-device inference, and
/// no risk of the model re-rolling into different or jargonier wording.
/// v1 caches (six fields) MUST keep loading: the Phase-3 additions decode
/// with `decodeIfPresent` defaults.
public struct CachedDiagnosis: Codable, Sendable {
    public let whatItIs: String
    public let whyItsProbablyHot: String
    public let isThisNormal: String
    public let suggestedAction: String
    public let actionSafetyTier: Int
    public let causallyLinkedProcesses: [String]
    public let anomalyKind: String
    public let judgedByModel: Bool
    /// Phase-3 additive fields — absent in v1 caches, defaulted on decode.
    public let isThisNormalVerdict: String
    public let confidenceNote: String
    /// Additive: the derived plain-English verdict headline (absent in v1/v2
    /// caches → "" on decode, re-derived by the view).
    public let verdict: String

    public init(card: DiagnosisCard, kind: Anomaly.Kind, judgedByModel: Bool) {
        whatItIs = card.whatItIs
        whyItsProbablyHot = card.whyItsProbablyHot
        isThisNormal = card.isThisNormal
        suggestedAction = card.suggestedAction
        actionSafetyTier = card.actionSafetyTier
        causallyLinkedProcesses = card.causallyLinkedProcesses
        anomalyKind = kind.rawValue
        self.judgedByModel = judgedByModel
        isThisNormalVerdict = card.isThisNormalVerdict
        confidenceNote = card.confidenceNote
        verdict = card.verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whatItIs = try c.decode(String.self, forKey: .whatItIs)
        whyItsProbablyHot = try c.decode(String.self, forKey: .whyItsProbablyHot)
        isThisNormal = try c.decode(String.self, forKey: .isThisNormal)
        suggestedAction = try c.decode(String.self, forKey: .suggestedAction)
        actionSafetyTier = try c.decode(Int.self, forKey: .actionSafetyTier)
        causallyLinkedProcesses = try c.decode([String].self, forKey: .causallyLinkedProcesses)
        anomalyKind = try c.decode(String.self, forKey: .anomalyKind)
        judgedByModel = try c.decode(Bool.self, forKey: .judgedByModel)
        isThisNormalVerdict = try c.decodeIfPresent(String.self, forKey: .isThisNormalVerdict)
            ?? DiagnosisCard.NormalVerdict.uncertain.rawValue
        confidenceNote = try c.decodeIfPresent(String.self, forKey: .confidenceNote) ?? ""
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
    }

    public var card: DiagnosisCard {
        DiagnosisCard(
            whatItIs: whatItIs, whyItsProbablyHot: whyItsProbablyHot,
            isThisNormal: isThisNormal, suggestedAction: suggestedAction,
            actionSafetyTier: actionSafetyTier, causallyLinkedProcesses: causallyLinkedProcesses,
            isThisNormalVerdict: isThisNormalVerdict, confidenceNote: confidenceNote,
            verdict: verdict
        )
    }
}

extension DiagnosisCard {
    /// The three calm-expert headline strings — the single source of truth so
    /// the derivation and any invariant check compare against the same words.
    public enum Verdict {
        public static let looksFine = "This looks fine"
        public static let worthALook = "Worth a look"
        public static let needsALook = "This needs a look"
    }

    /// The client-side verdict derivation — pure, per-machine, unit-testable.
    /// Turns the machine verdict (`isThisNormalVerdict`) into the calm-expert
    /// headline, gated so it can never contradict corpus severity:
    ///
    ///   likely_normal  → "This looks fine"
    ///   uncertain      → "Worth a look"
    ///   likely_abnormal→ "This needs a look"
    ///
    /// CONSISTENCY GATE — a never-normal-when-hot process can never be told
    /// "This looks fine". Safety tier ≥ 3 is exactly that population: the
    /// corpus marks databases, kernel_task and unknown processes explain-only
    /// because a hot one is never routine. Such a card is demoted to "Worth a
    /// look" even when the model read the baseline as normal. Thin evidence
    /// (low confidence) is held to the same bar — it never earns full
    /// reassurance, and a low-confidence abnormal call softens to "Worth a
    /// look" rather than shouting.
    ///
    /// The SAME gate closes on the offered action: a destructive primary
    /// button (Quit/Restart) can NEVER sit beside a reassuring headline. When
    /// the effective action is destructive — including the self-contradictory
    /// server response that pairs likely_normal with safe_action=quit — full
    /// reassurance is off the table and the headline softens to "Worth a look".
    /// Headline and action are thus derived from one consistent source and can
    /// never diverge.
    public static func deriveVerdict(
        isThisNormalVerdict raw: String,
        actionSafetyTier tier: Int,
        confidence: Confidence,
        offeredActionIsDestructive destructive: Bool = false
    ) -> String {
        // Tier ≥ 3 = never-normal-when-hot, thin evidence, OR a destructive
        // button offered: in every case "this looks fine" is off the table.
        let reassuranceAllowed = tier < 3 && confidence.level != .low && !destructive

        switch NormalVerdict(rawValue: raw) ?? .uncertain {
        case .likelyNormal:
            return reassuranceAllowed ? Verdict.looksFine : Verdict.worthALook
        case .uncertain:
            return Verdict.worthALook
        case .likelyAbnormal:
            return confidence.level == .low ? Verdict.worthALook : Verdict.needsALook
        }
    }
}
