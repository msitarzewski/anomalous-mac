import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Security)
import Security
#endif

/// Wakes only on anomaly. PROACTIVE-FIRST: attempt the model call in the
/// background at detection time (a few calls/day rarely trips the budget);
/// degrade to the knowledge-map-only card ONLY on rateLimited, and retry
/// at the next foreground-ish moment — never on a timer (projectRules.md #4,
/// seed.md rate-limit risk bullet).
///
/// Phase 3: rung 1 is a TOOL-CALLING session (processHistory / baseline /
/// correlated / corpusEntry over a JudgmentContext snapshot); rung 2 is a
/// non-blocking Private Cloud Compute upgrade pass (`pccUpgrade`); rung 3
/// (the paid backend) NEVER fires from here — "Get Help" stays an explicit
/// user tap (see AnomalousBackendModel).
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

    /// Pre-Phase-3 entry point — unchanged behavior (no tools).
    public func judge(_ anomaly: Anomaly, baselineSentence: String) async -> Outcome {
        await judge(anomaly, baselineSentence: baselineSentence, context: nil)
    }

    /// The on-device routing decision, factored out as a PURE function so the
    /// "should the model even be consulted?" gate is unit-testable without the
    /// model (which is availability-gated and non-deterministic). The model is
    /// consulted only when there is something solid to anchor on:
    ///   - a corpus identity (the known-daemon path), OR
    ///   - an app BUNDLE ID — the bundle NAMES the app, so the model describes
    ///     a known app (Chrome, VS Code, an Electron helper) instead of
    ///     inventing one. The bundle id is the hard fact that prevents
    ///     hallucination.
    /// A genuine mystery — NO corpus entry AND NO bundle (an unrecognizable
    /// daemon) — never reaches the model: it gets the deterministic
    /// conservative unknown card, which the opt-in discovery path can research.
    public enum Route: Sendable, Equatable {
        /// kernel_task: thermal-throttling symptom, deterministic reframe.
        case thermal
        /// A hung ("Not Responding") app: deterministic force-quit diagnosis.
        case hungApp
        /// No corpus entry AND no bundle id — a genuine mystery. Deterministic
        /// conservative unknown card; the model is NOT consulted.
        case deterministicUnknown
        /// Consult the model — corpus-grounded, or bundle-anchored (unknown
        /// app but the bundle id names it).
        case model
    }

    /// Decide the route from the anomaly and whether a grounding entry exists.
    /// Pure — no FoundationModels, no I/O.
    public static func route(for anomaly: Anomaly, hasCorpusEntry: Bool) -> Route {
        if anomaly.identity.executableName == "kernel_task" { return .thermal }
        if anomaly.kind == .appHung { return .hungApp }
        // The unknown gate: a flagged process with no corpus identity AND no
        // bundle to anchor on is a mystery daemon — stay conservative, don't
        // let the model guess. WITH a bundle id (a real app) we DO consult the
        // model, anchored on that identity.
        if !hasCorpusEntry, anomaly.identity.bundleID == nil { return .deterministicUnknown }
        return .model
    }

    /// Rung 1. With a `JudgmentContext` snapshot the session gets the four
    /// judgment tools; without one it behaves exactly like the pre-Phase-3
    /// single-shot call. All deterministic paths are identical either way.
    public func judge(_ anomaly: Anomaly, baselineSentence: String, context: JudgmentContext?) async -> Outcome {
        let entry = groundingEntry(for: anomaly, context: context)

        switch Self.route(for: anomaly, hasCorpusEntry: entry != nil) {
        case .thermal:
            // High kernel_task is thermal throttling — the SYMPTOM, not a
            // runaway. Never offer to kill the kernel; reframe as "your Mac
            // is hot" (memory-bank open question, now handled).
            return .mapOnlyCard(Self.thermalCard(anomaly: anomaly, baselineSentence: baselineSentence))
        case .hungApp:
            // A hung ("Not Responding") app: nothing for the model to diagnose
            // from CPU/RSS (both flat). The diagnosis is deterministic and the
            // same every time — force-quit and relaunch.
            return .mapOnlyCard(Self.hungAppCard(anomaly: anomaly, baselineSentence: baselineSentence))
        case .deterministicUnknown:
            // Genuine mystery: no corpus, no bundle anchor. The conservative
            // unknown card stands; the model would only be guessing. The
            // discovery path (opt-in, app side) can still research it.
            return .mapOnlyCard(Self.mapOnlyCard(anomaly: anomaly, entry: entry, baselineSentence: baselineSentence))
        case .model:
            break
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                do {
                    var tools: [any Tool] = context.map { JudgmentToolbox.tools(for: $0) } ?? []
                    var instructionsText = Self.instructions(
                        anomaly: anomaly, entry: entry,
                        baselineSentence: baselineSentence, toolsAvailable: !tools.isEmpty
                    )
                    // Budget everything inside the model's ACTUAL context
                    // window, read dynamically — never hard-coded (measured
                    // 4096 on this box; TN3193).
                    (instructionsText, tools) = await Self.fitToBudget(
                        model: model, instructions: instructionsText, tools: tools,
                        anomaly: anomaly, entry: entry, baselineSentence: baselineSentence
                    )
                    let session = LanguageModelSession(model: model, tools: tools, instructions: instructionsText)
                    let response = try await session.respond(
                        to: Self.cardPrompt,
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

    /// The grounding entry: the context's merged corpus (shipped + pulled,
    /// pulled wins) when a snapshot exists, else the shipped map.
    func groundingEntry(for anomaly: Anomaly, context: JudgmentContext?) -> KnowledgeEntry? {
        let name = anomaly.identity.executableName
        // Exact by observed name (context snapshot first, then merged map), then
        // the channel-aware fallback so a variant like dev.zed.Zed-Preview reuses
        // the base app's record instead of falling through to a model guess.
        return context?.corpusEntry(for: name)
            ?? knowledgeMap.entry(for: anomaly.identity)
    }

    static let cardPrompt = "Fill the diagnosis card for this anomaly."

    // MARK: - Rung 2: Private Cloud Compute (upgrade pass, never blocking)

    /// What actually happened when the PCC rung ran — the card, or the
    /// honest reason there isn't one. The base card has already rendered;
    /// this only ever upgrades it in place.
    public enum PCCUpgradeOutcome: Sendable {
        case upgraded(DiagnosisCard)
        /// Policy said the on-device card is good enough, or the OS/SDK
        /// can't run PCC at all.
        case notAttempted(String)
        /// PCC exists but reports itself unavailable at runtime
        /// (entitlement / eligibility / not ready).
        case unavailable(String)
        case failed(String)
        case timedOut

        public var card: DiagnosisCard? {
            if case .upgraded(let card) = self { return card }
            return nil
        }
    }

    /// Attempt the PCC rung for a low-confidence / thinly-grounded card.
    /// Fire-and-forget from the caller's perspective: the rung-1 card is
    /// already on screen; if this returns `.upgraded` within the timeout the
    /// caller swaps the card, otherwise nothing changes. Degrades silently
    /// on every failure mode — PCC may require an entitlement we don't have.
    public func pccUpgrade(
        _ anomaly: Anomaly,
        baselineSentence: String,
        context: JudgmentContext?,
        baseCard: DiagnosisCard,
        timeout: Duration = .seconds(15)
    ) async -> PCCUpgradeOutcome {
        let entry = groundingEntry(for: anomaly, context: context)
        guard EscalationPolicy.shouldUpgradeToPCC(
            confidence: anomaly.confidence.level,
            hasCorpusEntry: entry != nil,
            actionSafetyTier: baseCard.actionSafetyTier,
            verdict: baseCard.isThisNormalVerdict
        ) else {
            return .notAttempted("policy: on-device card is confident and grounded")
        }

        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *) else {
            return .notAttempted("macOS 27 API unavailable at runtime")
        }
        // MEASURED ON MAXBEAST (2026-07-05): `availability` reports
        // `.available` even without the PCC entitlement, and the first
        // respond() then FATAL-ERRORS (uncatchable trap inside
        // PrivateCloudComputeLanguageModel). The entitlement check is the
        // real capability gate; availability alone is a lie for unentitled
        // processes.
        guard Self.hasPrivateCloudComputeEntitlement() else {
            return .unavailable("missing entitlement com.apple.developer.private-cloud-compute — PCC respond() hard-traps without it")
        }
        let pcc = PrivateCloudComputeLanguageModel()
        switch pcc.availability {
        case .unavailable(let reason):
            return .unavailable(String(describing: reason))
        case .available:
            break
        }

        let instructionsText = Self.instructions(
            anomaly: anomaly, entry: entry,
            baselineSentence: baselineSentence, toolsAvailable: context != nil
        )
        let snapshot = context
        // The session is created INSIDE the racing task (LanguageModelSession
        // isn't Sendable); both tasks capture only Sendable values.
        return await withTaskGroup(of: PCCUpgradeOutcome?.self) { group in
            group.addTask {
                do {
                    let tools: [any Tool] = snapshot.map { JudgmentToolbox.tools(for: $0) } ?? []
                    let session = LanguageModelSession(model: pcc, tools: tools, instructions: instructionsText)
                    let response = try await session.respond(
                        to: Self.cardPrompt,
                        generating: DiagnosisCard.self,
                        contextOptions: ContextOptions(reasoningLevel: .deep)
                    )
                    return .upgraded(response.content)
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first ?? .timedOut
        }
        #else
        return .notAttempted("FoundationModels not present in this toolchain")
        #endif
    }

    /// Whether THIS process carries the PCC entitlement. Checked via
    /// SecTask because the FoundationModels availability API does not
    /// reflect it (see the measured note in `pccUpgrade`).
    static func hasPrivateCloudComputeEntitlement() -> Bool {
        #if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.private-cloud-compute" as CFString, nil
        ) else { return false }
        return (value as? Bool) == true
        #else
        return false
        #endif
    }

    // MARK: - Deterministic cards (byte-compatible with pre-Phase-3 output)

    /// Deterministic card from the knowledge map — already a complete
    /// diagnosis for known daemons ("dasd averaged 0.1% for 90 days; at
    /// 150% for 41h; safe to kill, launchd respawns it" needs zero LLM).
    /// The `whyItsProbablyHot` / `suggestedAction` fallbacks a knowledge-map card
    /// carries when the process is UNKNOWN (no corpus entry). Exposed so the
    /// discovery merge can detect and replace them once an identity arrives —
    /// otherwise the card shows "No identity information available" right above
    /// the identity discovery just fetched.
    public static let unknownWhyHot = "No identity information available; treat with caution."
    public static let unknownAction = "No action offered for unknown processes."

    static func mapOnlyCard(anomaly: Anomaly, entry: KnowledgeEntry?, baselineSentence: String) -> DiagnosisCard {
        DiagnosisCard(
            whatItIs: entry?.whatItIs ?? "Unknown process — not in the knowledge map.",
            whyItsProbablyHot: entry?.whenHotImplies ?? Self.unknownWhyHot,
            isThisNormal: baselineSentence,
            suggestedAction: entry?.safeAction ?? Self.unknownAction,
            actionSafetyTier: entry?.safetyTier ?? 3,
            causallyLinkedProcesses: entry?.causallyLinked ?? [],
            isThisNormalVerdict: DiagnosisCard.NormalVerdict.uncertain.rawValue,
            confidenceNote: "Detector confidence: \(anomaly.confidence.level.rawValue). Composed without AI from the curated knowledge map."
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
            causallyLinkedProcesses: [],
            isThisNormalVerdict: DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue,
            confidenceNote: "High confidence: kernel_task heat is a well-understood thermal-throttling symptom."
        )
    }

    /// A "Not Responding" app: the event loop is wedged, so CPU/RSS reveal
    /// nothing and there's nothing to infer. Deterministic map-only card —
    /// force-quit and relaunch. Tier 2 (warn first): quitting a stuck app is
    /// the standard fix but can lose unsaved work, so it's not one-click safe.
    static func hungAppCard(anomaly: Anomaly, baselineSentence: String) -> DiagnosisCard {
        let name = anomaly.identity.executableName
        let minutes = max(1, Int((anomaly.windowSeconds / 60).rounded()))
        let unit = minutes == 1 ? "minute" : "minutes"
        return DiagnosisCard(
            whatItIs: "\(name) has been unresponsive for \(minutes) \(unit) — it's stopped responding to input.",
            whyItsProbablyHot: "The app's main thread is blocked (a stuck operation, a wait that never returns, or a deadlock), so its window won't accept clicks or typing. This isn't high resource use — it's the opposite, a frozen app.",
            isThisNormal: baselineSentence,
            suggestedAction: "Force quit and relaunch it.",
            actionSafetyTier: 2,
            causallyLinkedProcesses: [],
            isThisNormalVerdict: DiagnosisCard.NormalVerdict.likelyAbnormal.rawValue,
            confidenceNote: "High confidence: the window server itself reports the app as not responding."
        )
    }

    // MARK: - Instructions (the grounding — empirically load-bearing)

    /// Pre-Phase-3 shape, kept for callers/tests that don't pass a context.
    static func instructions(anomaly: Anomaly, entry: KnowledgeEntry?, baselineSentence: String) -> String {
        instructions(anomaly: anomaly, entry: entry, baselineSentence: baselineSentence, toolsAvailable: false)
    }

    /// Embeds the Phase-2 detector facts VERBATIM — driving metric, baseline
    /// deviation (±infinity phrased defensively), graded confidence, system
    /// context. The ungrounded model called the founding busy-poll signature
    /// "normal behavior"; the detector's verdict is stated as decided, and
    /// the model only explains it.
    static func instructions(anomaly: Anomaly, entry: KnowledgeEntry?, baselineSentence: String, toolsAvailable: Bool) -> String {
        var lines: [String] = [
            "You compose a diagnosis card for a macOS process anomaly, for a non-expert.",
            "The DETECTOR has already judged this behavior anomalous — you explain it; you never re-detect or overrule the numbers.",
            "Ground every claim in the facts below\(toolsAvailable ? " and in tool results" : ""). Never invent identities, versions, numbers, or known issues.",
            "Quote numbers exactly as given; never recompute, estimate, or round them differently.",
        ]
        if toolsAvailable {
            lines.append("Tools: processHistory (the recent metric curve), baseline (what is normal for this process and how far off it is now), correlated (related observations this tick), corpusEntry (what a named process is). Call baseline before deciding isThisNormalVerdict.")
        }
        lines.append(contentsOf: [
            "If a fact is not provided, say so plainly rather than guessing.",
            "Write in plain English. NEVER expose internal jargon to the user:",
            "no rule names (e.g. 'cputime_ratio'), no internal field names (e.g. 'whenHotImplies'), no window sizes in minutes, no 'threshold', no 'MADs'.",
            // Brand voice: cards are read by non-technical people, not engineers.
            "Voice — speak to a non-technical adult (a busy parent, not an engineer): warm, plain, calm, reassuring.",
            "Say 'quit it' / 'stop it' / 'close it' — NEVER 'kill', 'terminate', 'SIGKILL'. Say 'macOS starts it back up on its own' or 'it comes right back' — NEVER 'respawn'. Say 'background helper' or the app's own name — avoid 'daemon'. Avoid 'in-flight', 'thrashing', 'launchd'.",
            "Accuracy still wins: never soften a real risk to sound friendly — if quitting is genuinely safe say so plainly; if it's better to wait, say why in plain terms.",
            "For 'isThisNormal': ONE short, calm sentence — is this normal, and how far from normal.",
            "",
            "Process: '\(anomaly.identity.executableName)'",
            "Observed: \(baselineSentence)",
            "Detector facts (state them, don't restate differently):",
            "- driving metric: \(anomaly.drivingMetric.isEmpty ? "unspecified" : anomaly.drivingMetric)",
            "- deviation from baseline: \(JudgmentToolFormatter.deviationPhrase(anomaly.baselineDeviation))",
            "- detector confidence: \(anomaly.confidence.level.rawValue) (\(String(format: "%.2f", anomaly.confidence.score)))",
        ])
        if let systemContext = anomaly.systemContext {
            lines.append("- machine context: \(systemContext)")
        }
        if !anomaly.alsoObserved.isEmpty {
            lines.append("- also observed: \(anomaly.alsoObserved.joined(separator: "; "))")
        }
        if anomaly.identity.bundleID != nil {
            // Emit the CANONICAL id (channel suffix stripped) so a "-Preview"
            // token never reaches the model as bait — see the bundle-anchored
            // block below. The channel, if any, is stated as a plain fact.
            let canonical = anomaly.identity.canonicalBundleID ?? anomaly.identity.bundleID!
            let channelNote = anomaly.identity.releaseChannel.map { " (\($0) release channel — same app, pre-release build)" } ?? ""
            lines.append("Bundle: \(canonical) version \(anomaly.identity.appVersion ?? "unknown")\(channelNote)")
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
                "Knowledge map — safeAction: \(entry.safeAction ?? "none — no safe intervention exists; explain only, offer no action")",
                "Knowledge map — safetyTier: \(entry.safetyTier)",
                "Knowledge map — causallyLinked: \(entry.causallyLinked.joined(separator: ", "))",
            ])
        } else if anomaly.identity.bundleID != nil {
            // No curated entry, but the bundle id NAMES the app — the hard fact
            // the model anchors on instead of inventing an identity. This is
            // the "we KNOW it's Chrome" path (com.google.Chrome.helper.*).
            // CRITICAL: use the CANONICAL id and forbid reading meaning out of
            // the string. A channel suffix ("-Preview") or role segment
            // ("-Helper") once got read as a *description* — the model saw
            // dev.zed.Zed-Preview and invented "a preview tool / close the
            // preview window." The id names the app; it is never a description.
            let canonical = anomaly.identity.canonicalBundleID ?? anomaly.identity.bundleID!
            var idLine = "No curated knowledge-map entry exists, but this process belongs to a known application, identified by its bundle id: \(canonical)\(anomaly.identity.appVersion.map { " (version \($0))" } ?? "")."
            if let channel = anomaly.identity.releaseChannel {
                idLine += " This is the \(channel) release channel of that SAME app — a pre-release/variant build, not a different or special-purpose program."
            }
            lines.append(contentsOf: [
                idLine,
                "The bundle id NAMES the app; it is not a description. NEVER infer what the process does from words or suffixes inside the id — a '-Preview'/'-Nightly'/'-Beta' segment is a release channel and a '-Helper'/'-Renderer' segment is a component role, neither is a feature to describe.",
                "Identify the app ONLY if you genuinely recognize it from the canonical bundle id. If you do, describe THAT app (browsers, editors, Electron apps, developer tools) and assess the anomaly factually. If you do NOT recognize it, say so plainly and stay conservative (safety tier 3) — never invent a purpose.",
            ])
        } else {
            lines.append("No knowledge-map entry and no app identity: this is an UNKNOWN process. Safety tier must be 3.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context budget

    #if canImport(FoundationModels)
    /// Tokens reserved for the generated card plus one round of tool
    /// call/output traffic inside the transcript.
    static let responseReserveTokens = 700
    static let toolTrafficReserveTokens = 500

    /// Fit instructions + tool schemas + card schema + prompt + reserves
    /// inside `model.contextSize` (read DYNAMICALLY — 4096 on this box).
    /// Trim order: (1) drop the tools (their schemas + traffic are the bulk),
    /// (2) fall back to the compact no-tools instructions. Never trims the
    /// detector facts — they are the grounding.
    @available(macOS 26.0, *)
    static func fitToBudget(
        model: SystemLanguageModel,
        instructions instructionsText: String,
        tools: [any Tool],
        anomaly: Anomaly,
        entry: KnowledgeEntry?,
        baselineSentence: String
    ) async -> (String, [any Tool]) {
        guard #available(macOS 26.4, *) else { return (instructionsText, tools) }
        let budget = model.contextSize
        do {
            let cost = try await promptCost(model: model, instructions: instructionsText, tools: tools)
            if cost + responseReserveTokens + (tools.isEmpty ? 0 : toolTrafficReserveTokens) <= budget {
                return (instructionsText, tools)
            }
            // Too big with tools — drop them and re-state the compact form.
            let compact = instructions(anomaly: anomaly, entry: entry, baselineSentence: baselineSentence, toolsAvailable: false)
            return (compact, [])
        } catch {
            // Token accounting unavailable — proceed optimistically; the
            // respond call itself still fails safe into the map-only card.
            return (instructionsText, tools)
        }
    }

    /// Instructions + tools + card schema + the fixed prompt, in tokens.
    @available(macOS 26.4, *)
    static func promptCost(model: SystemLanguageModel, instructions instructionsText: String, tools: [any Tool]) async throws -> Int {
        var total = try await model.tokenCount(for: Instructions(instructionsText))
        total += try await model.tokenCount(for: DiagnosisCard.generationSchema)
        total += try await model.tokenCount(for: cardPrompt)
        if !tools.isEmpty {
            total += try await model.tokenCount(for: tools)
        }
        return total
    }
    #endif
}

/// When to climb a rung — pure and table-testable. Cheap by default: the
/// on-device card stands unless confidence was low or grounding was thin
/// (unknown process, tier-3 "explain only", or the model itself said
/// "uncertain"). Rung 3 (paid backend) is NEVER selected here — money moves
/// only on an explicit user tap.
public enum EscalationPolicy {
    public static func shouldUpgradeToPCC(
        confidence: Confidence.Level,
        hasCorpusEntry: Bool,
        actionSafetyTier: Int,
        verdict: String
    ) -> Bool {
        if !hasCorpusEntry { return true }
        if actionSafetyTier >= 3 { return true }
        if confidence == .low { return true }
        if verdict == DiagnosisCard.NormalVerdict.uncertain.rawValue { return true }
        return false
    }
}
