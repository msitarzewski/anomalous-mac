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

    @Guide(description: "In plain, non-technical English, what is most likely happening and why — the 'what this means' that helps an ordinary person understand the situation. One or two short sentences, grounded in the knowledge map's whenHotImplies and QUOTING the observed numbers you were given (e.g. '1400 wakeups per second'). No jargon.")
    public var whyItsProbablyHot: String

    @Guide(description: "State what's normal for this process versus what's happening now, using the observed numbers (e.g. 'Normally about 0.1% CPU; now around 150% for 41 hours'). One line. No rule names or window sizes in minutes.")
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
    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String], isThisNormalVerdict: String, confidenceNote: String) {
        self.whatItIs = whatItIs
        self.whyItsProbablyHot = whyItsProbablyHot
        self.isThisNormal = isThisNormal
        self.suggestedAction = suggestedAction
        self.actionSafetyTier = actionSafetyTier
        self.causallyLinkedProcesses = causallyLinkedProcesses
        self.isThisNormalVerdict = isThisNormalVerdict
        self.confidenceNote = confidenceNote
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

    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String]) {
        self.init(
            whatItIs: whatItIs, whyItsProbablyHot: whyItsProbablyHot, isThisNormal: isThisNormal,
            suggestedAction: suggestedAction, actionSafetyTier: actionSafetyTier,
            causallyLinkedProcesses: causallyLinkedProcesses,
            isThisNormalVerdict: NormalVerdict.uncertain.rawValue, confidenceNote: ""
        )
    }

    public init(whatItIs: String, whyItsProbablyHot: String, isThisNormal: String, suggestedAction: String, actionSafetyTier: Int, causallyLinkedProcesses: [String], isThisNormalVerdict: String, confidenceNote: String) {
        self.whatItIs = whatItIs
        self.whyItsProbablyHot = whyItsProbablyHot
        self.isThisNormal = isThisNormal
        self.suggestedAction = suggestedAction
        self.actionSafetyTier = actionSafetyTier
        self.causallyLinkedProcesses = causallyLinkedProcesses
        self.isThisNormalVerdict = isThisNormalVerdict
        self.confidenceNote = confidenceNote
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
    }

    public var card: DiagnosisCard {
        DiagnosisCard(
            whatItIs: whatItIs, whyItsProbablyHot: whyItsProbablyHot,
            isThisNormal: isThisNormal, suggestedAction: suggestedAction,
            actionSafetyTier: actionSafetyTier, causallyLinkedProcesses: causallyLinkedProcesses,
            isThisNormalVerdict: isThisNormalVerdict, confidenceNote: confidenceNote
        )
    }
}
