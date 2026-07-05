import Foundation
import Observation
import AppKit
import AnomalousCore

/// The app's single source of state: drives the collector loop, keeps
/// per-process history, runs detection each tick, and judges anomalies.
/// Quiet by design — `anomalies` is empty almost always, and the UI shows
/// nothing when nothing is wrong.
@MainActor
@Observable
final class AppState {
    struct JudgedAnomaly: Identifiable {
        let id = UUID()
        let anomaly: Anomaly
        let card: DiagnosisCard
        let judgedByModel: Bool
        /// The grounded baseline sentence used for judgment — reused verbatim
        /// when composing an escalation payload (safe fields only).
        let baselineSentence: String
        var escalation: EscalationState = .idle

        var isApp: Bool { anomaly.identity.bundleID != nil }
        /// The concrete action offered, gated by the card's safety tier.
        var action: ProcessAction {
            ProcessAction.offered(tier: card.actionSafetyTier, kind: anomaly.kind, isApp: isApp)
        }
        /// Escalation earns its place when the local stack was thin: an
        /// unknown process, or an explain-only (tier-3) card. Known,
        /// confidently-actionable daemons don't need paid triage.
        var warrantsEscalation: Bool {
            !judgedByModel || card.actionSafetyTier >= 3
        }
    }

    enum EscalationState: Equatable {
        case idle, sending, sent(Int), completed(EscalationClient.ExpertResult), failed(String)
    }

    /// Result of attempting an action, surfaced transiently in the card.
    enum ActionResult: Equatable { case done, needsSudo(String), gone, identityChanged, failed }

    private(set) var anomalies: [JudgedAnomaly] = []
    private(set) var lastSampleAt: Date?
    private(set) var sampledProcessCount = 0
    private(set) var contributedCount = 0

    /// Contribution is core to the product (contributors are the supply
    /// side) — disclosed plainly in the popover, toggleable, and every
    /// send is in the byte-for-byte log the user can open.
    var contributionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "contributionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "contributionEnabled") }
    }

    let sendLogDirectory = URL.applicationSupportDirectory
        .appending(path: "Anomalous/send-log", directoryHint: .isDirectory)

    var serverDescription: String { serverBaseURL.absoluteString }

    /// Homebrew services, cached for the session (queried once, refreshable).
    /// Lets a card offer `brew services stop <formula>` — the correct remedy
    /// for a hot Homebrew service — instead of a raw kill.
    private(set) var brewServices: [BrewService] = []
    var brewIsAvailable: Bool { BrewServices.isAvailable }

    func refreshBrewServices() async {
        brewServices = await BrewServices.list()
    }

    /// Find the running Homebrew service backing a flagged process, if any.
    func brewService(for judged: JudgedAnomaly) -> BrewService? {
        guard judged.anomaly.identity.installSource == .homebrew else { return nil }
        return BrewServices.matchRunning(processExecutable: judged.anomaly.identity.executableName, in: brewServices)
    }

    @discardableResult
    func controlBrewService(_ action: String, _ service: BrewService, dismissing judged: JudgedAnomaly) async -> Bool {
        let ok = await BrewServices.control(action, service: service.name)
        if ok {
            await refreshBrewServices()
            if action == "stop" { dismiss(judged) }
        }
        return ok
    }

    private var serverBaseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["ANOMALOUS_SERVER"] ?? "http://127.0.0.1:8787")!
    }

    /// Account token for paid triage escalation. Empty until the user signs
    /// in (Settings). Escalation UI only appears when this is set — the
    /// account-linked paid path never fires anonymously.
    // Stored in the Keychain, not UserDefaults — it's a credential (the paid
    // account bearer token), and a UserDefaults plist is readable by any
    // process with the user's file access.
    var accountToken: String {
        get { Keychain.string(for: "accountToken") ?? "" }
        set { Keychain.set(newValue, for: "accountToken") }
    }
    var canEscalate: Bool { !accountToken.isEmpty }

    private let collector = Collector()
    /// Root helper — when installed, sampling covers root daemons (dasd,
    /// WindowServer, kernel_task…) the unprivileged collector can't see.
    let helper = HelperClient()
    private let ingestClient: IngestClient
    private let knowledgeMap: KnowledgeMap?
    /// Memory across launches: rolling baselines + already-flagged
    /// instances (the reason a relaunch doesn't re-diagnose the same runaway).
    private let baselineStore = BaselineStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Anomalous/baselines.json")
    )
    private let notifications = NotificationManager()
    private var history: [ProcessIdentity: [ProcessSample]] = [:]
    private var alreadyFlagged: Set<ProcessIdentity> = []
    /// Consecutive ticks a known process failed to sample (transient
    /// rusage failures must not reset long detection windows).
    private var missCounts: [ProcessIdentity: Int] = [:]
    private var monitorTask: Task<Void, Never>?
    /// Persist every ~15 min (10 ticks @ 90s), not every tick — a full
    /// snapshot encode + atomic rewrite each 90s is pure overhead on the
    /// <0.5% CPU layer; EWMAs tolerate losing a few minutes on unclean exit.
    private var ticksSinceSave = 0
    private static let saveEveryTicks = 10

    /// Production thresholds by default; ANOMALOUS_DEMO=1 loosens the
    /// ratio rule for demos (5-minute uptime, 5% ratio) — dev only.
    private let thresholds: DetectionThresholds

    init() {
        knowledgeMap = try? KnowledgeMap.shipped()
        var t = DetectionThresholds()
        if ProcessInfo.processInfo.environment["ANOMALOUS_DEMO"] != nil {
            t.cpuTimeRatio = 0.05
            t.cpuTimeRatioMinimumUptime = 300
            print("[anomalous] DEMO thresholds active")
        }
        thresholds = t

        let server = ProcessInfo.processInfo.environment["ANOMALOUS_SERVER"] ?? "http://127.0.0.1:8787"
        ingestClient = IngestClient(
            baseURL: URL(string: server)!,
            sendLog: SendLog(directory: sendLogDirectory)
        )
    }

    func startMonitoring(interval: TimeInterval = 90) {
        guard monitorTask == nil else { return }
        // When the user returns from System Settings (where they approve the
        // helper), re-check status promptly instead of waiting for the next
        // 90s tick — this is what keeps the install flow from feeling broken.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.helper.refreshOnActivate() }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func tick() async {
        await baselineStore.loadIfNeeded()
        helper.refreshStatus()
        // Always self-classify what we can see: the collector reads user
        // processes with full local metadata (bundle, version, INSTALL
        // SOURCE). The helper is ADDITIVE — it only fills in root-owned
        // processes the unprivileged collector can't read (dasd, WindowServer…).
        // This keeps install-source/version correct for user apps regardless
        // of the helper's version, and never loses the root tier.
        var byPid: [pid_t: ProcessSample] = [:]
        for sample in await collector.sampleAll() { byPid[sample.identity.pid] = sample }
        if let rootSamples = await helper.sampleAll() {
            for sample in rootSamples where byPid[sample.identity.pid] == nil {
                byPid[sample.identity.pid] = sample
            }
        }
        let samples = Array(byPid.values)
        lastSampleAt = .now
        sampledProcessCount = samples.count

        var detected: [Anomaly] = []

        for sample in samples {
            let previous = history[sample.identity]?.last
            history[sample.identity, default: []].append(sample)
            // Keep a bounded window per process (KISS: count-bound ≈ time-bound at fixed cadence).
            if history[sample.identity]!.count > 60 {
                history[sample.identity]!.removeFirst()
            }

            // Feed the rolling baseline (instantaneous CPU% needs two samples).
            if let previous {
                let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0 {
                    await baselineStore.record(
                        key: BaselineStore.key(for: sample.identity),
                        cpuPercent: (sample.cpuTimeSeconds - previous.cpuTimeSeconds) / dt * 100,
                        rssMB: Double(sample.residentBytes) / 1_048_576
                    )
                }
            }

            guard !alreadyFlagged.contains(sample.identity) else { continue }
            if await baselineStore.isFlagged(sample.identity) {
                alreadyFlagged.insert(sample.identity) // cache the persisted flag
                continue
            }

            if let anomaly = DetectionRules.cpuTimeRatioAnomaly(sample: sample, thresholds: thresholds)
                ?? DetectionRules.sustainedCPUAnomaly(history: history[sample.identity]!, baseline: nil, thresholds: thresholds)
                ?? DetectionRules.rssLeakAnomaly(history: history[sample.identity]!, thresholds: thresholds)
                ?? DetectionRules.rssCeilingAnomaly(sample: sample, thresholds: thresholds) {
                detected.append(anomaly)
                alreadyFlagged.insert(sample.identity)
                await baselineStore.markFlagged(sample.identity, kind: anomaly.kind)
                print("[anomalous] FLAGGED \(anomaly.kind.rawValue) in \(anomaly.identity.executableName) (pid \(anomaly.identity.pid), magnitude \(anomaly.magnitudeCurve.last.map { String(format: "%.1f", $0) } ?? "?"))")
            }
        }
        ticksSinceSave += 1
        if ticksSinceSave >= Self.saveEveryTicks || !detected.isEmpty {
            await baselineStore.pruneExpiredFlags()
            await baselineStore.save()
            ticksSinceSave = 0
        }
        print("[anomalous] tick: \(samples.count) processes, \(detected.count) new anomalies, \(anomalies.count + detected.count) active")

        // Evict state only after 3 consecutive missed ticks — a transient
        // rusage failure must not reset a 30-minute detection window.
        let live = Set(samples.map(\.identity))
        for identity in history.keys where !live.contains(identity) {
            let misses = (missCounts[identity] ?? 0) + 1
            if misses >= 3 {
                history[identity] = nil
                missCounts[identity] = nil
                alreadyFlagged.remove(identity)
            } else {
                missCounts[identity] = misses
            }
        }
        for identity in live { missCounts[identity] = nil }

        for anomaly in detected {
            await judge(anomaly)
            await contribute(anomaly)
        }
    }

    /// The supply-side stitch: anonymous signature → send log → ingest.
    /// Failure is silent-but-logged; contribution must never make the
    /// sensor noisy or spin the very fans it watches.
    private func contribute(_ anomaly: Anomaly) async {
        guard contributionEnabled else { return }
        do {
            let status = try await ingestClient.send(anomaly)
            if status == 202 { contributedCount += 1 }
            print("[anomalous] contributed signature for \(anomaly.identity.executableName): HTTP \(status)")
        } catch {
            print("[anomalous] contribution skipped (server unreachable): \(error.localizedDescription)")
        }
    }

    private func judge(_ anomaly: Anomaly) async {
        guard let knowledgeMap else { return }
        let processKey = BaselineStore.key(for: anomaly.identity)

        // Clean, human "so what" — the observed deviation in plain terms, no
        // rule names or window-in-minutes. What's normal + what's happening now.
        var baseline = Self.observation(for: anomaly)
        if let stats = await baselineStore.baseline(forKey: processKey) {
            baseline = stats.sentence + " " + baseline
        }

        // Cache-first: reuse the prior card for this process+condition so the
        // same answer shows every time — stable wording, no re-inference.
        if let cached = await baselineStore.cachedDiagnosis(processKey: processKey, kind: anomaly.kind) {
            let judged = JudgedAnomaly(anomaly: anomaly, card: cached.card, judgedByModel: cached.judgedByModel, baselineSentence: baseline)
            anomalies.append(judged)
            await notifications.post(for: judged)
            return
        }

        let engine = JudgmentEngine(knowledgeMap: knowledgeMap)
        let judged: JudgedAnomaly
        switch await engine.judge(anomaly, baselineSentence: baseline) {
        case .modelCard(let card):
            judged = JudgedAnomaly(anomaly: anomaly, card: card, judgedByModel: true, baselineSentence: baseline)
            print("[anomalous] CARD (model) \(anomaly.identity.executableName): \(card.whatItIs) → \(card.suggestedAction) [tier \(card.actionSafetyTier)]")
        case .mapOnlyCard(let card):
            judged = JudgedAnomaly(anomaly: anomaly, card: card, judgedByModel: false, baselineSentence: baseline)
            print("[anomalous] CARD (map-only) \(anomaly.identity.executableName): \(card.whatItIs) → \(card.suggestedAction) [tier \(card.actionSafetyTier)]")
        }
        await baselineStore.cacheDiagnosis(
            CachedDiagnosis(card: judged.card, kind: anomaly.kind, judgedByModel: judged.judgedByModel),
            processKey: processKey, kind: anomaly.kind
        )
        anomalies.append(judged)
        await notifications.post(for: judged)
    }

    func dismiss(_ judged: JudgedAnomaly) {
        anomalies.removeAll { $0.id == judged.id }
    }

    private let actuator = ProcessActuator()

    /// Perform the offered action. Caller (UI) is responsible for having
    /// confirmed destructive actions first — this method just executes.
    @discardableResult
    func perform(_ action: ProcessAction, on judged: JudgedAnomaly, force: Bool = false) async -> ActionResult {
        switch action {
        case .terminate, .restartApp:
            // Capture the app's bundle URL BEFORE killing, so a restart can
            // actually relaunch (the pid is gone afterward).
            let relaunchURL = action == .restartApp
                ? NSRunningApplication(processIdentifier: judged.anomaly.identity.pid)?.bundleURL
                : nil

            switch actuator.terminate(identity: judged.anomaly.identity, force: force) {
            case .success:
                if action == .restartApp, let relaunchURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.createsNewApplicationInstance = false
                    _ = try? await NSWorkspace.shared.openApplication(at: relaunchURL, configuration: config)
                }
                dismiss(judged)
                return .done
            case .failure(.notPermitted):
                // Root-owned: if the privileged helper is installed, it can
                // do the kill we can't. Otherwise fall back to the copy-paste
                // sudo command.
                if await helper.terminate(judged.anomaly.identity) {
                    dismiss(judged)
                    return .done
                }
                return .needsSudo(actuator.manualCommand(forExecutable: judged.anomaly.identity.executableName))
            case .failure(.noSuchProcess):
                dismiss(judged)
                return .gone
            case .failure(.identityChanged):
                // The pid was reused — the flagged process is already gone.
                // Never kill the stranger now holding its pid.
                dismiss(judged)
                return .identityChanged
            case .failure(.unsupported):
                return .failed
            }
        case .update:
            // Non-destructive: open the App Store Updates page so the user
            // can install the fix. (Direct-distribution apps update via their
            // own Sparkle-style mechanism, which we can't invoke generically.)
            if let url = URL(string: "macappstore://showUpdatesPage") {
                NSWorkspace.shared.open(url)
            }
            return .done
        case .explainOnly:
            return .done
        }
    }

    /// Escalate a thin local diagnosis to the paid triage service. Composes
    /// the account-linked payload (safe fields only — see PayloadComposer),
    /// logs it byte-for-byte, and POSTs it. Only reachable when an account
    /// token is configured; the anonymous flow is never involved.
    func escalate(_ judged: JudgedAnomaly) async {
        guard canEscalate, let index = anomalies.firstIndex(where: { $0.id == judged.id }) else { return }
        anomalies[index].escalation = .sending

        let payload = PayloadComposer().compose(
            anomaly: judged.anomaly,
            baselineSentence: judged.baselineSentence,
            osVersion: serverDescription.isEmpty ? "" : Self.osVersionString,
            hardwareClass: SignatureComposer.hardwareClass
        )
        let client = EscalationClient(
            baseURL: serverBaseURL,
            bearerToken: accountToken,
            sendLog: SendLog(directory: sendLogDirectory)
        )
        do {
            let accepted = try await client.escalate(payload)
            setEscalation(.sent(accepted.id), for: judged)
            print("[anomalous] escalated \(judged.anomaly.identity.executableName): triage #\(accepted.id)")
            // Receive half: poll for the expert diagnosis and show it.
            let result = try await client.awaitResult(id: accepted.id)
            setEscalation(.completed(result), for: judged)
            print("[anomalous] triage #\(accepted.id) result: \(result.suggestedAction ?? result.note ?? "—")")
        } catch {
            setEscalation(.failed(Self.escalationMessage(error)), for: judged)
            print("[anomalous] escalation failed: \(error)")
        }
    }

    private func setEscalation(_ state: EscalationState, for judged: JudgedAnomaly) {
        if let i = anomalies.firstIndex(where: { $0.id == judged.id }) {
            anomalies[i].escalation = state
        }
    }

    /// A plain-English statement of the observed deviation — the "so what,"
    /// with durations in human units (hours/days) and no internal rule names.
    private static func observation(for anomaly: Anomaly) -> String {
        let hours = anomaly.windowSeconds / 3600
        let duration: String
        if hours >= 48 { duration = "for \(Int(hours / 24)) days" }
        else if hours >= 1 { duration = "for \(Int(hours)) hours" }
        else { duration = "for under an hour" }
        let current = anomaly.magnitudeCurve.last ?? 0

        switch anomaly.kind {
        case .cpuTimeRatio, .sustainedCPU:
            return "It has now been running at about \(Int(current))% CPU \(duration)."
        case .rssLeak:
            return "Its memory has been climbing \(duration), now about \(Int(current)) MB."
        case .rssCeiling:
            return "It is using about \(Int(current)) MB of memory, far above what's expected."
        case .novelProcess:
            return "This process is new and unrecognized, and it's using significant resources."
        }
    }

    private static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func escalationMessage(_ error: Error) -> String {
        switch error {
        case EscalationClient.EscalationError.unauthorized: return "Sign in again"
        case EscalationClient.EscalationError.insufficientBalance: return "Add credit to escalate"
        default: return "Couldn't reach the service"
        }
    }
}
