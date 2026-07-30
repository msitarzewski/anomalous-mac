import Foundation

/// The card's title-row urgency cue — the EXCEPTION, not the rule.
///
/// Every card exists because the process ran above its own baseline, so the
/// on-device model marks almost all of them `likely_abnormal`. Above-baseline
/// is NOT the same as "worth worrying about": the card's mere existence is
/// already the heads-up. So the badge is driven by MAGNITUDE (how far above
/// normal, and how much of the whole machine it's eating) rather than by the
/// model's normal/abnormal verdict — and it stays SILENT in the common case.
///
///   • `.none`        — a mild/moderate elevation, or a normal-looking card.
///                      No badge. The card itself is the notice.
///   • `.worthALook`  — a genuinely NOTABLE deviation (amber).
///   • `.needsALook`  — STRICT/RARE, reserved for extreme magnitude on a
///                      KNOWN never-normal-when-hot process (corpus-marked,
///                      like a database), or a thermal emergency (muted red).
///                      A merely-unrecognized process never reaches red.
///
/// Pure and unit-testable: `classify` is a function of the inputs alone. The
/// magnitude bars are NAMED, TUNABLE constants (`Tuning`) so they can be
/// dialled in without hunting through the branch logic.
public enum UrgencyCue: Sendable, Equatable {
    case none
    case worthALook
    case needsALook

    /// The magnitude bars that separate quiet from notable from extreme.
    /// Deliberately conservative — the badge should be the exception. Tune
    /// here; the classifier reads these and nothing else.
    public enum Tuning {
        /// Below this ×-above-baseline reads as "a little / somewhat more" —
        /// quiet. At or above it the deviation is notable.
        public static let mildRatioCeiling: Double = 2.5
        /// Percent of a WHOLE resource (CPU / memory / GPU) that counts as
        /// notable on its own, regardless of ratio.
        public static let notableShareFloor: Double = 60
        /// ×-above-baseline that reads as extreme (red-eligible).
        public static let extremeRatio: Double = 6.0
        /// Percent of a whole resource that reads as extreme (red-eligible).
        public static let extremeShareFloor: Double = 90
    }

    /// Classify a flagged anomaly into an urgency cue.
    ///
    /// - Parameters:
    ///   - ratioAboveNormal: current ÷ the process's OWN baseline for the
    ///     driving metric. nil when there's no baseline to divide by.
    ///   - resourceSharePercent: 0…100 share of the whole machine/resource
    ///     (CPU / memory / GPU). nil when the kind has no whole-machine share.
    ///   - verdict: the on-device model's normal/abnormal read.
    ///   - tier: the card's action safety tier. ≥ 3 = never-normal-when-hot
    ///     (databases, kernel_task, unknown) — the only population red is for.
    ///   - lowConfidence: thin evidence — never earns the red badge.
    ///   - isFrozenApp: a hung / Not-Responding app (caution, not emergency).
    ///   - isThermal: the kernel_task thermal card (machine overheating).
    ///   - isGenuinelyUnknown: the corpus doesn't recognize this process, so its
    ///     tier-3 is only the UNKNOWN default, not a corpus-marked
    ///     never-normal-when-hot verdict. "We don't recognize it" is amber (worth
    ///     a look), never red — red is for a genuinely dangerous KNOWN situation.
    public static func classify(
        ratioAboveNormal: Double?,
        resourceSharePercent: Double?,
        verdict: DiagnosisCard.NormalVerdict,
        tier: Int,
        lowConfidence: Bool,
        isFrozenApp: Bool,
        isThermal: Bool,
        isGenuinelyUnknown: Bool
    ) -> UrgencyCue {
        // 1. Machine overheating is a genuine, rare emergency.
        if isThermal { return .needsALook }
        // 2. A frozen app is a caution (force-quit), never an emergency.
        if isFrozenApp { return .worthALook }
        // 3. The model read it as routine → the card existing is enough.
        if verdict == .likelyNormal { return .none }

        // 4. Is the deviation genuinely notable? A big ratio OR a big share.
        //    When neither magnitude signal exists (a metric with no baseline,
        //    e.g. a lifetime cputime-ratio), fall back to the model's read.
        let notable: Bool
        if ratioAboveNormal == nil && resourceSharePercent == nil {
            notable = (verdict == .likelyAbnormal)
        } else {
            notable = (ratioAboveNormal.map { $0 >= Tuning.mildRatioCeiling } ?? false)
                || (resourceSharePercent.map { $0 >= Tuning.notableShareFloor } ?? false)
        }
        // Mild / moderate → stay quiet. The card is the heads-up.
        guard notable else { return .none }

        // 5. Extreme magnitude on either axis.
        let extreme = (ratioAboveNormal.map { $0 >= Tuning.extremeRatio } ?? false)
            || (resourceSharePercent.map { $0 >= Tuning.extremeShareFloor } ?? false)

        // 6. Red is strict: extreme, confident, AND a KNOWN never-normal-when-hot
        //    process (corpus-marked tier ≥ 3, like a database). A GPU-heavy sim or
        //    a busy WindowServer (tier < 3) is at most amber, however extreme — and
        //    so is a genuinely-unknown process, whose tier-3 is only the UNKNOWN
        //    default ("we don't recognize it"), not a corpus verdict. Unrecognized
        //    tops out at amber; red means a dangerous situation we can name.
        return (extreme && !lowConfidence && tier >= 3 && !isGenuinelyUnknown)
            ? .needsALook : .worthALook
    }
}
