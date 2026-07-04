import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wakes only on anomaly. PROACTIVE-FIRST: attempt the model call in the
/// background at detection time (a few calls/day rarely trips the budget);
/// degrade to the knowledge-map-only card ONLY on rateLimited, and retry
/// at the next foreground-ish moment — never on a timer (projectRules.md #4,
/// seed.md rate-limit risk bullet).
public struct JudgmentEngine: Sendable {
    public enum Outcome: Sendable {
        /// Model produced a full card.
        case modelCard(DiagnosisCard)
        /// Rate-limited or model unavailable: deterministic map-only card.
        /// One fallback, two reasons (non-AI Macs share this path).
        case mapOnlyCard(DiagnosisCard)
    }

    private let knowledgeMap: KnowledgeMap

    public init(knowledgeMap: KnowledgeMap) {
        self.knowledgeMap = knowledgeMap
    }

    public func judge(_ anomaly: Anomaly, baselineSentence: String) async -> Outcome {
        // Special case: high kernel_task is thermal throttling — the SYMPTOM,
        // not a runaway. Never offer to kill the kernel; reframe as "your Mac
        // is hot" (memory-bank open question, now handled).
        if anomaly.identity.executableName == "kernel_task" {
            return .mapOnlyCard(Self.thermalCard(anomaly: anomaly, baselineSentence: baselineSentence))
        }

        let entry = knowledgeMap.entry(forProcessName: anomaly.identity.executableName)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                do {
                    let session = LanguageModelSession(
                        instructions: Self.instructions(anomaly: anomaly, entry: entry, baselineSentence: baselineSentence)
                    )
                    let response = try await session.respond(
                        to: "Fill the diagnosis card for this anomaly.",
                        generating: DiagnosisCard.self
                    )
                    return .modelCard(response.content)
                } catch {
                    // Whatever the error shape (rateLimited, guardrail,
                    // context overflow — enum cases shift across dot
                    // releases; match defensively), degrade honestly.
                    // Retry policy (next interaction, NEVER a timer) is the
                    // caller's concern.
                }
            }
        }
        #endif

        return .mapOnlyCard(Self.mapOnlyCard(anomaly: anomaly, entry: entry, baselineSentence: baselineSentence))
    }

    /// Deterministic card from the knowledge map — already a complete
    /// diagnosis for known daemons ("dasd averaged 0.1% for 90 days; at
    /// 150% for 41h; safe to kill, launchd respawns it" needs zero LLM).
    static func mapOnlyCard(anomaly: Anomaly, entry: KnowledgeEntry?, baselineSentence: String) -> DiagnosisCard {
        DiagnosisCard(
            whatItIs: entry?.whatItIs ?? "Unknown process — not in the knowledge map.",
            whyItsProbablyHot: entry?.whenHotImplies ?? "No identity information available; treat with caution.",
            isThisNormal: baselineSentence,
            suggestedAction: entry?.safeAction ?? "No action offered for unknown processes.",
            actionSafetyTier: entry?.safetyTier ?? 3,
            causallyLinkedProcesses: entry?.causallyLinked ?? []
        )
    }

    /// kernel_task is unkillable and its heat means the machine is hot;
    /// the useful diagnosis points at what's heating it, not at itself.
    static func thermalCard(anomaly: Anomaly, baselineSentence: String) -> DiagnosisCard {
        DiagnosisCard(
            whatItIs: "kernel_task is the macOS kernel. High kernel_task CPU is the system deliberately occupying cores to force thermal throttling — it's a symptom, not a runaway.",
            whyItsProbablyHot: "Your Mac is running hot. Look for the process actually generating the heat, and check airflow, ambient temperature, and whether it's charging under load.",
            isThisNormal: baselineSentence,
            suggestedAction: "Don't kill kernel_task (you can't). Find and address the process heating the machine, and improve cooling.",
            actionSafetyTier: 3,
            causallyLinkedProcesses: []
        )
    }

    static func instructions(anomaly: Anomaly, entry: KnowledgeEntry?, baselineSentence: String) -> String {
        // Token-budget NOTE: query contextSize at runtime when available;
        // the map entry is the grounding and must fit. Keep this compact.
        var lines: [String] = [
            "You compose a diagnosis card for a macOS process anomaly, for a non-expert.",
            "Ground every claim in the facts below. Never invent identities, versions, or known issues.",
            "If a fact is not provided, say so plainly rather than guessing.",
            "Write in plain English. NEVER expose internal jargon to the user:",
            "no rule names (e.g. 'cputime_ratio'), no window sizes in minutes, no 'threshold'.",
            "For 'isThisNormal': ONE short, calm sentence — is this normal, and how far from normal.",
            "",
            "Process: '\(anomaly.identity.executableName)'",
            "Observed: \(baselineSentence)",
        ]
        if let bundleID = anomaly.identity.bundleID {
            lines.append("Bundle: \(bundleID) version \(anomaly.identity.appVersion ?? "unknown")")
        }
        // Hard facts — state these correctly, never guess them.
        lines.append("Runs as: \(anomaly.identity.ownerIsRoot ? "root (a system account)" : "the user's own account"). Do NOT describe the process's ownership any other way.")
        // Install provenance sharpens both identity and remediation.
        lines.append("Install source: \(anomaly.identity.installSource.phrase).")
        if let hint = anomaly.identity.installSource.lifecycleHint {
            lines.append("Remediation note: \(hint)")
        }
        if let entry {
            lines.append(contentsOf: [
                "Knowledge map — whatItIs: \(entry.whatItIs)",
                "Knowledge map — whenHotImplies: \(entry.whenHotImplies)",
                "Knowledge map — safeAction: \(entry.safeAction ?? "none — explain only")",
                "Knowledge map — safetyTier: \(entry.safetyTier)",
                "Knowledge map — causallyLinked: \(entry.causallyLinked.joined(separator: ", "))",
            ])
        } else {
            lines.append("No knowledge-map entry: this is an UNKNOWN process. Safety tier must be 3.")
        }
        return lines.joined(separator: "\n")
    }
}
