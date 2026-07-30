import Foundation

/// Normalizes a raw per-process reading to a fraction of the WHOLE machine —
/// the ceiling a person actually believes in ("% of my Mac"), not the per-core
/// figure Activity Monitor shows (where 100% is one core and a busy process
/// legitimately exceeds it). Pure and injectable: the machine facts default to
/// this Mac but are parameters so the math is unit-testable at any size.
///
/// This is the fix for GitHub #2 ("84% CPU" read as "almost my whole Mac" when
/// it was ~8% of a 10-core machine): language, anchored to a believable
/// ceiling, carries the meaning — see the verdict-first card design.
public enum MachineLoad {
    /// Per-core CPU percent (Activity Monitor's figure — 100% = one full core,
    /// can exceed 100 × cores) → percent of the machine's TOTAL processing
    /// power (0…100, one fully-saturated machine = 100). Divides by the active
    /// core count.
    public static func machineCPUPercent(
        perCorePercent: Double,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Double {
        guard cores > 0 else { return perCorePercent }
        // A process can't use more than the whole machine — clamp so the
        // believable ceiling ("% of my Mac") never reads above 100%.
        return min(100, max(0, perCorePercent / Double(cores)))
    }

    /// Resident megabytes → percent of installed physical memory (0…100).
    public static func memoryPercent(
        megabytes: Double,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Double {
        let totalMB = Double(physicalBytes) / (1024 * 1024)
        guard totalMB > 0 else { return 0 }
        return megabytes / totalMB * 100
    }

    /// A calm, plain rendering of a whole-machine percentage: "about 35%", or
    /// "less than 1%" for the vanishingly small (a bare "0%" reads as "nothing
    /// is happening", the opposite of a flagged anomaly).
    public static func approxPercent(_ percent: Double) -> String {
        // Never render a whole-machine share above 100% (or below 0%).
        let p = min(100, max(0, percent))
        if p < 1 { return "less than 1%" }
        return "about \(Int(p.rounded()))%"
    }
}

/// The three shapes a "what's happening" glance sentence can take, chosen by
/// how the current reading relates to what's normal. Language — not a gauge —
/// carries the meaning (card design), so the SHAPE picks the phrasing:
///   • a spike leads with the multiple ("~2.4× its usual"),
///   • an ordinary reading that simply won't stop leads with the duration,
///   • a near-zero baseline drops the multiple entirely (dividing by ~0 makes
///     "500× its usual" — technically true, uselessly alarming).
/// Anchored to a whole-machine ceiling throughout ("your total processing
/// power" / "your memory") — never the per-core figure that confuses people.
public enum MachineGlance {
    /// Which believable ceiling the percentage is measured against.
    public enum Resource: Sendable {
        case processor, memory
        var ceiling: String {
            switch self {
            case .processor: return "your total processing power"
            case .memory: return "your memory"
            }
        }
    }

    public enum Shape: Equatable, Sendable {
        /// now ≫ normal — a spike; carries the multiple over usual.
        case spike(multiple: Double)
        /// now ≈ normal but sustained — the duration is the story.
        case duration
        /// baseline ≈ 0 — the multiple would be meaningless, so drop it.
        case nearZeroBaseline
    }

    /// Classify by how far the current whole-machine reading sits above its
    /// learned whole-machine baseline. `spikeRatio` is the "how many × usual
    /// counts as a spike" bar; `nearZeroPercent` is the machine-share below
    /// which a baseline is "almost none" and the multiple is dropped.
    public static func shape(
        currentMachinePercent: Double,
        baselineMachinePercent: Double,
        spikeRatio: Double = 1.8,
        nearZeroPercent: Double = 0.5
    ) -> Shape {
        if baselineMachinePercent < nearZeroPercent { return .nearZeroBaseline }
        let ratio = currentMachinePercent / baselineMachinePercent
        return ratio >= spikeRatio ? .spike(multiple: ratio) : .duration
    }

    /// A "~2.4×" / "~2×" multiple, kept coarse: the point is the order of
    /// magnitude over usual, not spurious precision.
    static func multipleText(_ multiple: Double) -> String {
        if multiple >= 10 { return "about \(Int(multiple.rounded()))×" }
        // One decimal, but drop a trailing ".0" so 2.0 reads "2×".
        let rounded = (multiple * 10).rounded() / 10
        if rounded == rounded.rounded() { return "about \(Int(rounded))×" }
        return "about \(String(format: "%.1f", rounded))×"
    }

    /// Build the shape-aware glance clause. `duration` is a ready-made phrase
    /// that already begins with "for " (e.g. "for 9 days") so the duration
    /// shape reads "…but non-stop for 9 days."
    public static func sentence(
        resource: Resource,
        currentMachinePercent: Double,
        baselineMachinePercent: Double,
        duration: String,
        durationIsMeaningful: Bool = true,
        spikeRatio: Double = 1.8,
        nearZeroPercent: Double = 0.5
    ) -> String {
        let head = "\(MachineLoad.approxPercent(currentMachinePercent)) of \(resource.ceiling)"
        switch shape(
            currentMachinePercent: currentMachinePercent,
            baselineMachinePercent: baselineMachinePercent,
            spikeRatio: spikeRatio,
            nearZeroPercent: nearZeroPercent
        ) {
        case .spike(let multiple):
            return "\(head), \(multipleText(multiple)) its usual"
        case .duration:
            switch resource {
            case .processor:
                // "non-stop" is the sustained-CPU story — but only when there's
                // actually a duration worth citing. On a fresh flag "non-stop for
                // 1 second" is nonsense, so just say it's above its usual.
                return durationIsMeaningful
                    ? "\(head), but non-stop \(duration)"
                    : "\(head), above its usual"
            case .memory:
                // Memory is a LEVEL, not continuous activity — it is never
                // "non-stop", and its duration isn't the story; the level vs.
                // usual is.
                return "\(head), a little more than usual"
            }
        case .nearZeroBaseline:
            return "\(head), normally almost none"
        }
    }
}
