import Foundation
import Observation
import AppKit
import WidgetKit
import AnomalousCore
import IOKit.ps

/// The app's single source of state: drives the collector loop, keeps
/// per-process history, runs detection each tick, and judges anomalies.
/// Quiet by design — `anomalies` is empty almost always, and the UI shows
/// nothing when nothing is wrong.
@MainActor
@Observable
final class AppState {
    /// The single app-wide state. `@State private var appState = AppState()` in
    /// the App struct could be initialized more than once — leaving the tick
    /// loop mutating one instance while the UI observed another (detection
    /// worked but nothing ever showed). One instance, referenced everywhere.
    static let shared = AppState()

    /// State of the opt-in discovery lookup for a genuinely-unknown process.
    /// Distinct from paid escalation: discovery is anonymous and free.
    enum DiscoveryState: Equatable {
        case none
        /// A lookup is in flight — the card shows "Sourced by Anomalous —
        /// looking this up…".
        case researching
        /// The card was upgraded from an Anomalous-sourced assessment — the
        /// "Sourced by Anomalous" attribution shows.
        case sourced
        /// Research produced a confident answer the independent verifier couldn't
        /// clear for the corpus. The card shows the answer, captioned as
        /// unverified research at the given confidence ("high"/"medium").
        case researched(confidence: String?)
        /// The API honestly couldn't identify it — keep the unknown card.
        case notRecognized
        case failed(String)
    }

    struct JudgedAnomaly: Identifiable {
        let id = UUID()
        let anomaly: Anomaly
        var card: DiagnosisCard
        let judgedByModel: Bool
        /// The grounded baseline sentence used for judgment — reused verbatim
        /// when composing an escalation payload (safe fields only).
        let baselineSentence: String
        var escalation: EscalationState = .idle
        /// Discovery (opt-in identity lookup) state and any cited sources it
        /// returned. `sourced`/sources drive the "Sourced by Anomalous" UI.
        var discovery: DiscoveryState = .none
        var discoverySources: [DiscoveryClient.Assessment.Source] = []
        /// The card has no real identity — no corpus entry, and the on-device
        /// model had no bundle to anchor on (or wasn't available). Only these
        /// warrant a discovery lookup; a thermal/hung/known card never does.
        var genuinelyUnknown: Bool = false
        /// Set the moment the anomaly clears (process recovered or exited). The
        /// card shows a brief "resolved" state, then the tick removes it and
        /// records it in the journal. nil = still active.
        var resolvedAt: Date? = nil
        var isResolved: Bool { resolvedAt != nil }
        /// The anti-mute marker: set when an ACKNOWLEDGED condition earned its
        /// way back (materially worse / new instance / snooze expired). The
        /// card and widget show it as icon + words, never color alone.
        var returnedWorse: String? = nil
        /// Transient state while the user's "Check again" (Verify) runs — a
        /// live re-check of the metric, so a card that's actually calmed down
        /// can clear without waiting ~25–90 min for the window/median to decay.
        var verifyStatus: VerifyStatus? = nil
        /// Journal-derived recurrence: this process+kind genuinely resolved
        /// (recovered / exited / was handled) before and has now re-tripped as
        /// a *fresh* detection. Drives the "First flagged … · returned N×"
        /// footer so a flapping process reads as an ongoing saga, not a fresh
        /// one-minute blip. Distinct from `returnedWorse` (the anti-mute marker
        /// for an ACKNOWLEDGED/snoozed condition earning its way back).
        var recurrence: RecurrenceSummary? = nil

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

        enum VerifyStatus: Equatable { case checking, stillActive, couldntCheck }
    }

    enum EscalationState: Equatable {
        /// `needsCredit` is distinct from `failed`: the fix isn't "retry", it's
        /// "top up" — so the card offers Add credit (→ Account), not Retry.
        case idle, sending, sent(Int), completed(EscalationClient.ExpertResult), needsCredit, failed(String)
    }

    /// Which Settings tab to show — lets a card deep-link (e.g. "Add credit" →
    /// Account). Bound to the Settings `TabView` selection.
    enum SettingsTab: Hashable { case general, account, privacy, transparency, about }
    var settingsTab: SettingsTab = .general

    /// Result of attempting an action, surfaced transiently in the card.
    enum ActionResult: Equatable { case done, needsSudo(String), gone, identityChanged, failed }

    private(set) var anomalies: [JudgedAnomaly] = []
    /// This tick's medium/low-confidence findings — detected but NOT
    /// surfaced (only high confidence earns a card/notification; the
    /// quiet-by-design posture). Retained for a future UI and for dogfood
    /// tuning via the log; replaced wholesale each tick.
    private(set) var quietFindings: [Anomaly] = []
    private(set) var lastSampleAt: Date?
    private(set) var sampledProcessCount = 0
    private(set) var contributedCount = 0
    /// System-wide context captured alongside each tick's samples (memory
    /// pressure, swap, thermal, load). No UI reads it yet — Phase 2's
    /// judgment core consumes it to weigh anomalies against machine state.
    private(set) var systemSignals: SystemSignals?

    /// Contribution is core to the product (contributors are the supply
    /// side) — disclosed plainly in the popover, toggleable, and every
    /// send is in the byte-for-byte log the user can open.
    var contributionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "contributionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "contributionEnabled") }
    }

    /// Granular consent, SEPARATE from contribution: when Anomalous doesn't
    /// recognize a process, look it up via the API to get a real answer
    /// ("Sourced by Anomalous"). Default ON — the whole point is to stop the
    /// dead-end shrug. Every lookup is in the send log; a per-card "Look it
    /// up" tap can still discover a single process while this is OFF.
    var discoveryEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "discoveryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "discoveryEnabled") }
    }

    /// True while the popover is showing. Discovery polling stops when it
    /// closes (the result still lands in the corpus server-side for next time).
    var popoverIsOpen = true

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
            if action == "stop" { dismiss(judged, reason: .actioned) }
        }
        return ok
    }

    private var serverBaseURL: URL {
        URL(string: Self.resolvedServer)!
    }

    /// UserDefaults keys for the HIDDEN developer switch (revealed by an
    /// option-click in Settings › Transparency, then a password). The dev
    /// server override only applies once dev features are unlocked — a normal
    /// user, who never unlocks, is always on production regardless of these
    /// keys. The account + escalation ("Get Help") calls read `serverBaseURL`
    /// live, so flipping the server takes effect on the next request; the
    /// ingest/corpus clients are built at init, so a relaunch fully applies.
    static let devUnlockedKey = "devUnlocked"
    static let devServerEnabledKey = "devServerEnabled"
    static let devServerURLKey = "devServerURL"
    static let defaultDevServer = "http://localhost:8091"

    /// One-way hash of the developer password, baked into the app. The Settings
    /// unlock hashes what the user types (SHA-256 of "ANOMALOUS_DEV::" + input)
    /// and compares to this — the password itself is never stored or
    /// recoverable. This gate HIDES dev UI from normal users; it is not a
    /// security boundary (the binary is on-device). The actual safety is the
    /// loopback-only `isAllowedOverride`. Placeholder below never matches a real
    /// password — dev features stay locked until the real hash is baked in.
    static let devPasswordHash = "efc84df9fc799a353a6981cc57541b3644e7bbf47dcda7c02c4215b510bc1c50"

    /// The server the app talks to, resolved in order: (1) the ANOMALOUS_SERVER
    /// env var (scripted/dev launches), (2) the developer override — ONLY when
    /// dev features are unlocked AND the switch is on, (3) production. The
    /// override is restricted to a LOOPBACK host in release builds — a shipped
    /// app can only ever be pointed at the user's OWN machine for local testing,
    /// never redirected to a rogue remote that would capture the account token
    /// and triage payloads.
    static var resolvedServer: String {
        if let env = ProcessInfo.processInfo.environment["ANOMALOUS_SERVER"], !env.isEmpty {
            return env
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: devUnlockedKey), defaults.bool(forKey: devServerEnabledKey) {
            let url = defaults.string(forKey: devServerURLKey) ?? defaultDevServer
            if !url.isEmpty, isAllowedOverride(url) { return url }
        }
        return "https://api.anomalous.bot"
    }

    /// Guard the override so a release build can't be aimed at an arbitrary
    /// remote host. Delegates to the shared, unit-tested `ServerOverridePolicy`;
    /// this wrapper only supplies the build configuration. Debug builds allow
    /// any host (LAN dev servers, etc.); release builds are loopback-only.
    static func isAllowedOverride(_ urlString: String) -> Bool {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return ServerOverridePolicy.isAllowedOverride(urlString, isDebug: isDebug)
    }

    /// Account token for paid triage escalation. Empty until the user signs
    /// in (Settings). Escalation UI only appears when this is set — the
    /// account-linked paid path never fires anonymously.
    // Persisted in the Keychain, not UserDefaults — it's a credential (the paid
    // account bearer token), and a UserDefaults plist is readable by any
    // process with the user's file access. But the value must ALSO be a tracked
    // stored property, not a bare Keychain-backed computed one: under
    // @Observable, writes to a computed property are invisible to SwiftUI, so a
    // token pasted into the Settings SecureField never re-enabled the "Verify"
    // button (it stayed .disabled on a stale empty read). Stored + didSet keeps
    // the Keychain as the durable store while making edits observable. The
    // initializer seeds from the Keychain; didSet does not fire during init.
    var accountToken: String = Keychain.string(for: "accountToken") ?? "" {
        didSet { Keychain.set(accountToken, for: "accountToken") }
    }
    var canEscalate: Bool { !accountToken.isEmpty }

    /// Verified account state — the Account tab flips on this, not on a merely
    /// non-empty token. `.active` means the server confirmed the token (so we
    /// can thank the user for real); `.invalid` carries a human message.
    enum AccountStatus: Equatable {
        case signedOut
        case verifying
        case active(balanceCents: Int)
        case invalid(String)
    }
    private(set) var accountStatus: AccountStatus = .signedOut

    /// Transient feedback for the "Add funds" flow (Settings › Account).
    var topupStatus: String?
    var topupInFlight = false

    /// Transient feedback for the invite → create-account flow.
    var createStatus: String?
    var createInFlight = false

    /// Verify the stored token against the server and load the balance. This is
    /// what flips the Account tab from "sign in" to the "thank you" state:
    /// `.active` only after the server actually accepts the token. Reuses the
    /// existing balance endpoint (200 = valid) — no separate verify call.
    func verifyAccount() async {
        let token = accountToken
        guard !token.isEmpty else { accountStatus = .signedOut; return }
        if case .active = accountStatus {} else { accountStatus = .verifying }
        var request = URLRequest(url: serverBaseURL.appending(path: "/api/v1/account/balance"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch code {
            case 200:
                let cents = (json?["balance_cents"] as? Int) ?? (json?["cents"] as? Int) ?? 0
                accountStatus = .active(balanceCents: cents)
            case 401:
                accountStatus = .invalid("That token was rejected. Double-check it and try again.")
            default:
                accountStatus = .invalid("Couldn't reach your account (\(code)). Try again shortly.")
            }
        } catch {
            accountStatus = .invalid("Network error — check your connection and try again.")
        }
    }

    /// Redeem an invite code to create an account: the server consumes the
    /// single-use invite atomically and returns a bearer token, which we store
    /// (Keychain) and immediately verify. Detection stays free either way —
    /// this only unlocks the premium expert-help layer.
    func createAccount(inviteCode: String, email: String) async {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { createStatus = "Enter your invite code."; return }
        guard mail.contains("@") else { createStatus = "Enter a valid email for your account."; return }
        createInFlight = true
        createStatus = nil
        defer { createInFlight = false }

        var request = URLRequest(url: serverBaseURL.appending(path: "/api/v1/account/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["invite_code": code, "email": mail])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 201, let token = json?["token"] as? String, !token.isEmpty {
                accountToken = token
                await verifyAccount()
                createStatus = nil
            } else if status == 422 {
                createStatus = (json?["message"] as? String) ?? "That invite code isn't valid or has already been used."
            } else if status == 429 {
                createStatus = "Too many attempts — please wait a minute and try again."
            } else {
                createStatus = "Couldn't create your account (\(status)). Try again shortly."
            }
        } catch {
            createStatus = "Network error — check your connection and try again."
        }
    }

    /// Sign out: clear the token and reset the account state (local only —
    /// nothing is revoked server-side; the token simply stops being used here).
    func signOutAccount() {
        accountToken = ""
        accountStatus = .signedOut
        createStatus = nil
    }

    /// Start a prepaid top-up: ask the server for a Stripe Checkout URL and open
    /// it in the browser. The balance is only credited by the server's webhook
    /// once payment completes — this just opens checkout.
    func addFunds(amountCents: Int) async {
        guard canEscalate else { topupStatus = "Sign in first (paste your account token)."; return }
        topupInFlight = true
        topupStatus = nil
        defer { topupInFlight = false }

        var request = URLRequest(url: serverBaseURL.appending(path: "/api/v1/account/topup"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accountToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["amount_cents": amountCents])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if code == 201, let urlString = json?["checkout_url"] as? String, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                topupStatus = "Opening secure checkout in your browser…"
            } else if code == 503 {
                topupStatus = "Payments aren't enabled yet. Please try again later."
            } else if code == 401 {
                topupStatus = "Your account token was rejected — paste a fresh one."
            } else {
                topupStatus = "Couldn't start checkout (\(code)). Please try again."
            }
        } catch {
            topupStatus = "Network error — check your connection and try again."
        }
    }

    private let collector = Collector()
    /// Root helper — when installed, sampling covers root daemons (dasd,
    /// WindowServer, kernel_task…) the unprivileged collector can't see.
    let helper = HelperClient()
    /// One-time-per-session guard: reconcile a stale helper (post-update version
    /// skew) exactly once, before the first root sample benefits from it.
    private var helperReconciled = false
    private let ingestClient: IngestClient
    /// Anonymous, opt-in identity research for genuinely-unknown processes —
    /// same send-log/attestation pattern as ingest.
    private let discoveryClient: DiscoveryClient
    private var knowledgeMap: KnowledgeMap?
    /// Corpus feed grounding (Phase 6): pulls the reviewed, Ed25519-signed
    /// corpus and merges it OVER the shipped map — reviewed + newer wins.
    private let corpusClient: CorpusFeedClient
    /// Memory across launches: rolling baselines + already-flagged
    /// instances (the reason a relaunch doesn't re-diagnose the same runaway).
    private let baselineStore = BaselineStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Anomalous/baselines.json")
    )
    /// Reviewable history of resolved anomalies (local only). A card that
    /// clears on its own moves here instead of silently vanishing.
    private let journal = AnomalyJournal(
        fileURL: URL.applicationSupportDirectory.appending(path: "Anomalous/journal.json")
    )
    /// Phase 4: "normal for me" envelopes + snoozes, per condition
    /// (`process lineage · kind · dimension`). Local-only, same persistence
    /// pattern as the baseline store.
    private let ackStore = AcknowledgmentStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Anomalous/acknowledgments.json")
    )
    /// Spent widget-command nonces — replay defense for the App Group command
    /// channel. Deliberately in the app's OWN Application Support (not the
    /// shared container) so a forging process can't wipe the replay record.
    private let nonceStore = SeenNonceStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Anomalous/widget-nonces.json")
    )
    /// Recent journal entries, for the History/Journal view.
    private(set) var journalEntries: [JournalEntry] = []
    /// How long a card lingers in its "resolved" state before the tick removes it.
    private static let resolvedLingerSeconds: TimeInterval = 6
    private let notifications = NotificationManager()
    /// Phase 5: IOReport rail-power reader (cumulative energy counters —
    /// watts are Δ-energy between ticks, so the reader keeps the previous
    /// sample; MainActor-owned, never shared).
    private let railPower = RailPowerReader()
    private var history: [ProcessIdentity: [ProcessSample]] = [:]
    private var alreadyFlagged: Set<ProcessIdentity> = []
    /// Consecutive ticks a known process failed to sample (transient
    /// rusage failures must not reset long detection windows).
    private var missCounts: [ProcessIdentity: Int] = [:]
    /// When a GUI app first became unresponsive (nil once it's responding again).
    private var unresponsiveSince: [ProcessIdentity: Date] = [:]
    private var journalLoaded = false
    /// Persist every ~15 min (10 ticks @ 90s), not every tick — a full
    /// snapshot encode + atomic rewrite each 90s is pure overhead on the
    /// <0.5% CPU layer; EWMAs tolerate losing a few minutes on unclean exit.
    private var ticksSinceSave = 0
    private static let saveEveryTicks = 10

    /// Production thresholds by default; ANOMALOUS_DEMO=1 loosens the
    /// ratio rule for demos (5-minute uptime, 5% ratio) — dev only.
    private let thresholds: DetectionThresholds

    init() {
        let server = Self.resolvedServer
        // Fail-closed by default: an unsigned or unverifiable corpus feed is
        // rejected and the last verified corpus (or the shipped map alone)
        // stands. ANOMALOUS_ALLOW_UNSIGNED_FEED=1 is the dev override for a
        // local server that has no signing key configured.
        let corpus = CorpusFeedClient(
            baseURL: URL(string: server)!,
            requireSignedFeed: ProcessInfo.processInfo.environment["ANOMALOUS_ALLOW_UNSIGNED_FEED"] == nil
        )
        corpusClient = corpus
        knowledgeMap = (try? KnowledgeMap.shipped()).map { corpus.mergedKnowledgeMap(base: $0) }
        var t = DetectionThresholds()
        if ProcessInfo.processInfo.environment["ANOMALOUS_DEMO"] != nil {
            t.cpuTimeRatio = 0.05
            t.cpuTimeRatioMinimumUptime = 300
            print("[anomalous] DEMO thresholds active")
        }
        thresholds = t

        // Mint the shared HMAC key on first launch (idempotent). The widget
        // reads it from the same Keychain access group to sign the commands it
        // enqueues; the app verifies every command against it before acting.
        _ = SharedSecret.key(createIfMissing: true)

        ingestClient = IngestClient(
            baseURL: URL(string: server)!,
            sendLog: SendLog(directory: sendLogDirectory)
        )
        discoveryClient = DiscoveryClient(
            baseURL: URL(string: server)!,
            sendLog: SendLog(directory: sendLogDirectory)
        )

        // Notification actions (Snooze / Normal for me / Investigate) call
        // back into the same acknowledgment paths the card buttons use.
        notifications.onSnoozeCondition = { [weak self] key in
            Task { @MainActor in await self?.snoozeCondition(key: key, seconds: 3600) }
        }
        notifications.onAcknowledgeCondition = { [weak self] key in
            Task { @MainActor in await self?.acknowledgeCondition(key: key) }
        }

        // App Intents bridge: intents running IN this process act on live
        // state; in the widget process these stay nil and the intents fall
        // back to the App Group command queue. (Closures capture weak self —
        // touching AppState.shared here would recurse its own initializer.)
        IntentBridge.statusProvider = { [weak self] in self?.currentSensorStatus() ?? SensorStatus() }
        IntentBridge.runScan = { [weak self] in await self?.scanNow() }
        IntentBridge.snoozeAll = { [weak self] seconds in self?.snoozeAllAlerts(for: seconds) }
        IntentBridge.acknowledgeCondition = { [weak self] key in await self?.acknowledgeCondition(key: key) }
        IntentBridge.snoozeCondition = { [weak self] key, seconds in await self?.snoozeCondition(key: key, seconds: seconds) }
        IntentBridge.setMonitoring = { [weak self] enabled in self?.monitoringEnabled = enabled }
        IntentBridge.anomalyEntities = { [weak self] in self?.currentAnomalyEntities() ?? [] }

        // Widget/Control Center actions land as commands in the App Group
        // container; a name-only distributed notification nudges us to drain
        // promptly (the tick drains too, as the fallback).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(SensorStatus.commandNotification), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.applyWidgetCommands() }
        }
    }

    // MARK: - Monitoring loop (NSBackgroundActivityScheduler + backoff)

    /// The repeating background activity replacing the raw Timer loop: the
    /// system already defers it under battery/thermal/CPU pressure, and we
    /// add explicit backoff on top (interval ×3, skip the helper round-trip)
    /// when thermal state ≥ serious or Low Power Mode is on — the model-
    /// citizen behavior macOS 27's background-activity transparency surfaces.
    private var activity: NSBackgroundActivityScheduler?
    /// Base cadence ADAPTS to the power source — faster when there's wall power
    /// to spend (the full tick measures ~0.4% CPU), gentler on battery — with a
    /// ×3 thermal / Low-Power backoff on top.
    private static let acInterval: TimeInterval = 60       // plugged in
    private static let batteryInterval: TimeInterval = 90  // on battery
    private static let intervalTolerance: TimeInterval = 30
    private static let backoffMultiplier: TimeInterval = 3
    /// The interval last handed to the scheduler — so a thermal/power/plug
    /// change only reschedules when the effective cadence actually moves.
    private var scheduledInterval: TimeInterval = 0
    /// True while thermally/power constrained (read by tick to skip the
    /// helper XPC round-trip — the most expensive probe).
    private(set) var backoffActive = false
    private var observersRegistered = false
    /// Kept alive so IOKit keeps delivering AC⇄battery change callbacks.
    private var powerSourceSource: CFRunLoopSource?

    /// Power-source-adaptive base interval, before backoff. Desktops (no
    /// battery) and unknown states read as AC — there's nothing to protect.
    var baseInterval: TimeInterval {
        Self.onACPower() ? Self.acInterval : Self.batteryInterval
    }
    /// The cadence handed to the scheduler: base × backoff.
    private var effectiveInterval: TimeInterval {
        backoffActive ? baseInterval * Self.backoffMultiplier : baseInterval
    }

    /// Whether the Mac is on wall power. Desktops (no battery) and unknown
    /// states read as AC — the faster cadence, nothing to conserve.
    private static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPSACPowerValue
    }

    /// Monitoring on/off — the Control Center toggle's backing state. Lives
    /// in the App Group defaults so the control can render current state
    /// from its own process.
    var monitoringEnabled: Bool {
        get { Self.groupDefaults?.object(forKey: "monitoringEnabled") as? Bool ?? true }
        set {
            Self.groupDefaults?.set(newValue, forKey: "monitoringEnabled")
            if newValue { startMonitoring() } else { stopMonitoring() }
            publishWidgetStatus()
        }
    }
    static let groupDefaults = UserDefaults(suiteName: SensorStatus.appGroupID)

    func startMonitoring() {
        guard activity == nil, monitoringEnabled else { return }
        registerObserversIfNeeded()
        refreshBackoffFlag()
        // Immediate first tick on launch — the scheduler's first fire can be
        // minutes out; "first check in progress" must not be.
        Task { [weak self] in await self?.tick() }
        scheduleActivity()
    }

    func stopMonitoring() {
        activity?.invalidate()
        activity = nil
    }

    private func scheduleActivity() {
        activity?.invalidate()
        scheduledInterval = effectiveInterval
        let scheduler = NSBackgroundActivityScheduler(identifier: "bot.anomalous.sensor.tick")
        scheduler.repeats = true
        scheduler.interval = scheduledInterval
        scheduler.tolerance = Self.intervalTolerance
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            // The scheduler calls on its own queue; hop to the main actor for
            // the tick, then report finished so deferral heuristics stay honest.
            nonisolated(unsafe) let done = completion
            Task { @MainActor in
                await self?.tick()
                done(.finished)
            }
        }
        activity = scheduler
    }

    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }
        observersRegistered = true
        // When the user returns from System Settings (where they approve the
        // helper), re-check status promptly instead of waiting for the next
        // 90s tick — this is what keeps the install flow from feeling broken.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.helper.refreshOnActivate() }
        }
        // Thermal state and Low Power Mode → re-evaluate cadence + backoff.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluateCadence() }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluateCadence() }
        }
        // AC⇄battery plug changes ride a separate IOKit run-loop source — the
        // notifications above fire only for Low Power Mode, not for plugging in.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            Task { @MainActor in Unmanaged<AppState>.fromOpaque(raw).takeUnretainedValue().reevaluateCadence() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceSource = source
        }
    }

    /// Recompute whether we're thermally / Low-Power constrained (the tick
    /// reads `backoffActive` to skip the helper probe). Pure — no reschedule.
    private func refreshBackoffFlag() {
        let info = ProcessInfo.processInfo
        backoffActive = info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            || info.isLowPowerModeEnabled
    }

    /// React to a thermal / Low-Power / AC⇄battery change: recompute the
    /// effective cadence and reschedule ONLY if it actually moved (AC⇄battery =
    /// 60⇄90s; thermal/Low-Power = ×3 on top). Cheap when nothing changed.
    private func reevaluateCadence() {
        refreshBackoffFlag()
        guard activity != nil, effectiveInterval != scheduledInterval else { return }
        print("[anomalous] cadence → \(Int(effectiveInterval))s (base \(Int(baseInterval))s\(backoffActive ? ", thermal/low-power ×3" : ""))")
        scheduleActivity()
    }

    /// One immediate scan — the RunScanIntent / Control Center button path.
    func scanNow() async {
        await tick()
    }

    /// Reentrancy guard: a RunScan command draining DURING a tick must not
    /// recurse into a second tick.
    private var ticking = false

    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        // Re-evaluate cadence + backoff every tick, not only on system
        // notifications: a thermal cool-down, Low Power Mode toggle, or AC⇄
        // battery change whose notification the app missed would otherwise
        // leave the wrong cadence (or backoff stuck ON, skipping the helper
        // probe forever and making system-wide monitoring look off).
        reevaluateCadence()
        await baselineStore.loadIfNeeded()
        await ackStore.loadIfNeeded()
        if !journalLoaded {
            await journal.loadIfNeeded()
            journalEntries = await journal.recent()
            journalLoaded = true
        }
        // Widget/Control Center commands queued since the last nudge (the
        // distributed notification is best-effort; the tick is the backstop).
        await applyWidgetCommands()
        helper.refreshStatus()
        // Self-heal a stale helper left by an app update (version skew) once per
        // session, BEFORE sampling — so a fresh build starts watching root
        // daemons again with no user action instead of silently falling back to
        // user-only. A pre-feature helper can't self-restart; that one
        // transition needs a manual restart, then every update self-heals.
        if !helperReconciled, case .installed = helper.status {
            helperReconciled = true
            _ = await helper.reconcileVersion()
        }
        // Corpus refresh (fire-and-forget, idempotent under 24h): on an
        // update, re-merge over the shipped map so new reviewed identities
        // ground cards mid-session. Failures are silent — the last verified
        // corpus (or the shipped map) stands; grounding never blocks a tick.
        Task { [weak self] in
            guard let self else { return }
            if let outcome = try? await self.corpusClient.refreshIfStale(),
               case .updated = outcome,
               let shipped = try? KnowledgeMap.shipped() {
                self.knowledgeMap = self.corpusClient.mergedKnowledgeMap(base: shipped)
            }
        }
        // Always self-classify what we can see: the collector reads user
        // processes with full local metadata (bundle, version, INSTALL
        // SOURCE). The helper is ADDITIVE — it only fills in root-owned
        // processes the unprivileged collector can't read (dasd, WindowServer…).
        // This keeps install-source/version correct for user apps regardless
        // of the helper's version, and never loses the root tier.
        // Under thermal/low-power backoff the helper XPC round-trip (the most
        // expensive probe) is skipped — user-tier coverage continues.
        var byPid: [pid_t: ProcessSample] = [:]
        let (userSamples, gpuDevice) = await collector.sampleTick()
        for sample in userSamples { byPid[sample.identity.pid] = sample }
        if !backoffActive, let rootSamples = await helper.sampleAll() {
            for sample in rootSamples where byPid[sample.identity.pid] == nil {
                byPid[sample.identity.pid] = sample
            }
        }
        let samples = Array(byPid.values)
        lastSampleAt = .now
        sampledProcessCount = samples.count
        // One machine-wide snapshot per tick, timestamp-aligned with the
        // per-process samples above (a few cheap sysctls — the CPU budget
        // holds), plus the Phase 5 sensor context: SoC temperature, rail
        // power, and the GPU device snapshot the collector's IOKit pass
        // already produced. Each is independently nil when its SPI is dark.
        systemSignals = SystemSignals.read().withProSignals(
            socTemperatureCelsius: SoCTemperature.read(),
            railPowerWatts: railPower.sample(),
            gpuDevice: gpuDevice
        )

        var detected: [Anomaly] = []
        var quiet: [Anomaly] = []
        // Anti-mute re-alerts fired this tick: identity → marker string the
        // card shows ("returned, worse…").
        var realertMarkers: [ProcessIdentity: String] = [:]
        // Identities that are anomalous THIS tick (newly detected or still-active
        // flagged). Anything shown but NOT in here has resolved — see the prune below.
        var activeIds: Set<ProcessIdentity> = []

        for sample in samples {
            let previous = history[sample.identity]?.last
            history[sample.identity, default: []].append(sample)
            // Keep a bounded window per process (KISS: count-bound ≈ time-bound at fixed cadence).
            if history[sample.identity]!.count > 60 {
                history[sample.identity]!.removeFirst()
            }

            // Responsiveness (hung-app detection): for GUI apps, track how long
            // the process has been not-responding. The candidate chain reads this
            // to fire/keep an `app_hung` anomaly; clearing it on recovery lets the
            // standard auto-clear resolve the card.
            if sample.identity.bundleID != nil {
                if UnresponsiveProbe.isUnresponsive(pid: sample.identity.pid) {
                    if unresponsiveSince[sample.identity] == nil { unresponsiveSince[sample.identity] = .now }
                } else {
                    unresponsiveSince[sample.identity] = nil
                }
            }

            // Flag status FIRST — it decides whether this tick's readings may
            // teach the baseline: a flagged runaway burning for two days must
            // not teach the store that burning is normal (only Phase 4's
            // explicit acknowledgment may move the envelope).
            if !alreadyFlagged.contains(sample.identity), await baselineStore.isFlagged(sample.identity) {
                alreadyFlagged.insert(sample.identity)
            }
            let flagged = alreadyFlagged.contains(sample.identity)

            // Feed baselines and fetch the judgment inputs in ONE actor hop
            // (Δ-rates need two samples; a first-seen process records nothing
            // and judges nothing — the outermost warm-up).
            var judgment: [BaselineMetric: SelectedBaseline] = [:]
            if let previous {
                let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0 {
                    let tick = await baselineStore.recordTick(
                        key: BaselineStore.key(for: sample.identity),
                        at: sample.timestamp,
                        observations: Self.tickObservations(previous: previous, current: sample, dt: dt),
                        feedBaselines: !flagged,
                        seasonalMinimum: thresholds.seasonalMinimumObservations
                    )
                    judgment = tick.baselines
                }
            }

            // EVERY rule's verdict, not first-match: agreement across
            // dimensions is the confidence signal, and grouping needs the
            // full set to pick a primary.
            let candidates = candidateAnomalies(for: sample, judgment: judgment)

            // Already diagnosed this instance (in-memory this session, or a
            // persisted flag from a previous launch). Don't re-diagnose or
            // re-notify — but DO re-surface the cached card if this is STILL a
            // live runaway and it isn't currently on screen. The visible list
            // is in-memory, so after a relaunch a persistent anomaly (dasd)
            // would otherwise hide behind "All systems nominal" until the flag
            // expires. A known runaway must never be silently hidden.
            if flagged {
                if stillActive(sample, candidates: candidates) { activeIds.insert(sample.identity) }
                if let ackSuppressed = await resurfaceIfStillActive(sample, candidates: candidates) {
                    // Acked-within-envelope: off the UI, but visible in the
                    // quiet findings (transparency panel) — never invisible.
                    quiet.append(ackSuppressed)
                }
                continue
            }

            guard !candidates.isEmpty else { continue }
            let scored = ConfidenceEngine.annotate(candidates, signals: systemSignals)
            guard let primary = AnomalyGrouper.collapseSameProcess(scored) else { continue }
            if primary.confidence.level == .high {
                // Phase 4 acknowledgment gate, at the surfacing site: a
                // condition the user marked "normal for me" stays off the UI
                // while it holds inside its envelope. The anti-mute guarantee
                // re-alerts (with a marker) when it is materially worse, a new
                // process instance, or a snooze expired — and the re-alert
                // SPENDS the acknowledgment so it can never suppress again.
                switch await ackStore.decide(
                    key: Self.conditionKey(for: primary),
                    currentMagnitude: primary.magnitudeCurve.last ?? 0,
                    processStartAbsTime: sample.identity.startAbsTime
                ) {
                case .suppress:
                    quiet.append(primary)
                    print("[anomalous] acked-normal: \(primary.kind.rawValue) in \(primary.identity.executableName) within envelope — kept quiet")
                case .realert(let reason):
                    realertMarkers[sample.identity] = Self.realertMarker(for: reason)
                    detected.append(primary)
                    activeIds.insert(sample.identity)
                case .notAcknowledged:
                    detected.append(primary)
                    activeIds.insert(sample.identity)
                }
            } else {
                // Detected but below the surfacing bar: keep it quietly —
                // never a card, never a notification (the FP moat). Phase 4's
                // envelope and a future UI read these.
                quiet.append(primary)
                print("[anomalous] quiet finding: \(primary.kind.rawValue) in \(primary.identity.executableName) (confidence \(primary.confidence.level.rawValue) \(String(format: "%.2f", primary.confidence.score)), \(primary.drivingMetric) \(primary.baselineDeviation.map { String(format: "%.1f", $0) } ?? "?") MADs)")
            }
        }
        quietFindings = quiet

        // Correlation across processes: causally-linked anomalies from the
        // SAME tick collapse into one insight (dasd↔appstoreagent). Absorbed
        // ones are still flagged (or they'd refire as their own card next
        // tick — the exact fatigue grouping exists to kill).
        let (kept, absorbed) = AnomalyGrouper.groupCausallyLinked(detected) { causallyLinked($0, $1) }
        for anomaly in absorbed {
            alreadyFlagged.insert(anomaly.identity)
            await baselineStore.markFlagged(anomaly.identity, kind: anomaly.kind)
            print("[anomalous] GROUPED \(anomaly.kind.rawValue) in \(anomaly.identity.executableName) into a causally-linked insight")
        }
        detected = kept
        for anomaly in detected {
            alreadyFlagged.insert(anomaly.identity)
            await baselineStore.markFlagged(anomaly.identity, kind: anomaly.kind)
            print("[anomalous] FLAGGED \(anomaly.kind.rawValue) in \(anomaly.identity.executableName) (pid \(anomaly.identity.pid), magnitude \(anomaly.magnitudeCurve.last.map { String(format: "%.1f", $0) } ?? "?"), confidence \(String(format: "%.2f", anomaly.confidence.score)))")
        }
        print("[anomalous] tick: \(samples.count) processes, \(detected.count) new anomalies, \(quiet.count) quiet, \(anomalies.count + detected.count) active")

        // Evict state only after 3 consecutive missed ticks — a transient
        // rusage failure must not reset a 30-minute detection window.
        let live = Set(samples.map(\.identity))
        for identity in history.keys where !live.contains(identity) {
            let misses = (missCounts[identity] ?? 0) + 1
            if misses >= 3 {
                history[identity] = nil
                missCounts[identity] = nil
                alreadyFlagged.remove(identity)
                unresponsiveSince[identity] = nil
            } else {
                missCounts[identity] = misses
            }
        }
        for identity in live { missCounts[identity] = nil }

        // Auto-clear (the inverse of resurfacing): a shown card whose process is
        // no longer anomalous (recovered) or has exited (ended) gets a brief
        // resolved state, is recorded in the journal, then removed on a later
        // tick. Exit uses the same miss grace as history eviction so a transient
        // sampling failure never "resolves" a still-running runaway.
        for i in anomalies.indices where anomalies[i].resolvedAt == nil {
            let identity = anomalies[i].anomaly.identity
            guard !activeIds.contains(identity) else { continue }
            let ended = !live.contains(identity)
            if ended, (missCounts[identity] ?? 0) < 2 { continue }
            anomalies[i].resolvedAt = .now
            await recordResolution(anomalies[i], reason: ended ? .ended : .recovered)
        }
        anomalies.removeAll { judged in
            guard let resolvedAt = judged.resolvedAt else { return false }
            return Date.now.timeIntervalSince(resolvedAt) >= Self.resolvedLingerSeconds
        }

        for anomaly in detected {
            await judge(anomaly, returnedWorse: realertMarkers[anomaly.identity])
            await contribute(anomaly)
        }

        // Persist AFTER judging: judge() writes the diagnosis cache, so saving
        // earlier would persist a flag with NO cached card — and on the next
        // launch the flagged runaway couldn't be re-surfaced (it would hide
        // behind "All systems nominal"). Save every N ticks, or whenever we
        // judged something new.
        ticksSinceSave += 1
        if ticksSinceSave >= Self.saveEveryTicks || !detected.isEmpty {
            await baselineStore.pruneExpiredFlags()
            await baselineStore.save()
            ticksSinceSave = 0
        }

        // Reflect this tick's state into the App Group for the widget.
        publishWidgetStatus()
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

    /// Whether a card warrants a discovery lookup: no corpus identity, and the
    /// on-device model had no bundle to anchor on (or wasn't available). Pure —
    /// reuses the engine's routing gate so app and engine never disagree.
    static func genuinelyUnknown(anomaly: Anomaly, hasCorpusEntry: Bool, judgedByModel: Bool) -> Bool {
        guard !hasCorpusEntry else { return false }
        switch JudgmentEngine.route(for: anomaly, hasCorpusEntry: false) {
        case .thermal, .hungApp: return false
        case .deterministicUnknown: return true      // no bundle — a mystery
        case .model: return !judgedByModel           // bundle app the model couldn't identify / no model
        }
    }

    /// Look back over the local journal for prior *genuinely-resolved* episodes
    /// of the same identity + kind — a process that recovered, exited, or was
    /// handled and is now flagging again. Pure logic lives in
    /// `RecurrenceFinder` (tested in AnomalousCore); this just feeds it the
    /// live journal. Returns nil for a genuine first flag.
    private func recurrenceInfo(for anomaly: Anomaly) -> RecurrenceSummary? {
        RecurrenceFinder.summary(
            kind: anomaly.kind.rawValue,
            bundleID: anomaly.identity.bundleID,
            processName: anomaly.identity.executableName,
            detectedAt: anomaly.detectedAt,
            in: journalEntries,
            now: .now
        )
    }

    private func judge(_ anomaly: Anomaly, returnedWorse: String? = nil) async {
        guard let knowledgeMap else { return }
        // A process that genuinely cleared and re-tripped: fold its saga into
        // the footer. Skipped when the anti-mute marker already tells the
        // "came back" story, so the two never double up.
        let recurrence = returnedWorse == nil ? recurrenceInfo(for: anomaly) : nil
        let processKey = BaselineStore.key(for: anomaly.identity)
        // Channel-aware: a variant like dev.zed.Zed-Preview resolves to the base
        // app's record, so it is NOT treated as unknown (which would fire a
        // needless discovery and let a model guess stand). Mirrors the engine.
        let hasCorpusEntry = knowledgeMap.entry(for: anomaly.identity) != nil

        // Clean, human "so what" — the observed deviation in plain terms, no
        // rule names or window-in-minutes. What's normal + what's happening now.
        var baseline = Self.observation(for: anomaly)
        if let stats = await baselineStore.baseline(forKey: processKey),
           let grounding = stats.groundingSentence(currentCPUPercent: anomaly.magnitudeCurve.last ?? 0, kind: anomaly.kind) {
            baseline = grounding + " " + baseline
        }

        // Cache-first: reuse the prior card for this process+condition so the
        // same answer shows every time — stable wording, no re-inference.
        if let cached = await baselineStore.cachedDiagnosis(processKey: processKey, kind: anomaly.kind) {
            var judged = JudgedAnomaly(anomaly: anomaly, card: cached.card, judgedByModel: cached.judgedByModel, baselineSentence: baseline)
            judged.returnedWorse = returnedWorse
            judged.recurrence = recurrence
            judged.genuinelyUnknown = Self.genuinelyUnknown(
                anomaly: anomaly, hasCorpusEntry: hasCorpusEntry, judgedByModel: cached.judgedByModel
            )
            anomalies.append(judged)
            await notifySurfaced(judged)
            maybeDiscover(judged)
            return
        }

        let engine = JudgmentEngine(knowledgeMap: knowledgeMap)

        // Grounded facts for the tool-calling session (Phase 3): history and
        // robust baseline for the driving metric, corpus identities for this
        // process + its causal neighbors. Pure data — the tools never reach
        // back into app state, and the model quotes these numbers verbatim.
        var corpusEntries: [String: KnowledgeEntry] = [:]
        for name in [anomaly.identity.executableName]
            + (knowledgeMap.entry(forProcessName: anomaly.identity.executableName)?.causallyLinked ?? []) {
            if let entry = knowledgeMap.entry(forProcessName: name) { corpusEntries[name] = entry }
        }
        var histories: [JudgmentContext.MetricHistory] = []
        var baselineFacts: [JudgmentContext.MetricBaseline] = []
        if let metric = BaselineMetric(rawValue: anomaly.drivingMetric) {
            histories.append(.init(metric: metric, values: Array(anomaly.magnitudeCurve.suffix(8)), windowSeconds: anomaly.windowSeconds))
            if let stats = await baselineStore.robustStats(forKey: processKey, metric: metric) {
                baselineFacts.append(.init(metric: metric, stats: stats, isSeasonal: false, deviation: anomaly.baselineDeviation))
            }
        }
        let context = JudgmentContext(
            processName: anomaly.identity.executableName,
            histories: histories,
            baselines: baselineFacts,
            alsoObserved: anomaly.alsoObserved,
            corpusEntries: corpusEntries
        )

        var judged: JudgedAnomaly
        switch await engine.judge(anomaly, baselineSentence: baseline, context: context) {
        case .modelCard(let card):
            judged = JudgedAnomaly(anomaly: anomaly, card: card, judgedByModel: true, baselineSentence: baseline)
            print("[anomalous] CARD (model) \(anomaly.identity.executableName): \(card.whatItIs) → \(card.suggestedAction) [tier \(card.actionSafetyTier)]")
        case .mapOnlyCard(let card):
            judged = JudgedAnomaly(anomaly: anomaly, card: card, judgedByModel: false, baselineSentence: baseline)
            print("[anomalous] CARD (map-only) \(anomaly.identity.executableName): \(card.whatItIs) → \(card.suggestedAction) [tier \(card.actionSafetyTier)]")
        }
        judged.returnedWorse = returnedWorse
        judged.recurrence = recurrence
        judged.genuinelyUnknown = Self.genuinelyUnknown(
            anomaly: anomaly, hasCorpusEntry: hasCorpusEntry, judgedByModel: judged.judgedByModel
        )
        await baselineStore.cacheDiagnosis(
            CachedDiagnosis(card: judged.card, kind: anomaly.kind, judgedByModel: judged.judgedByModel),
            processKey: processKey, kind: anomaly.kind
        )
        anomalies.append(judged)
        await notifySurfaced(judged)
        maybeDiscover(judged)

        // Rung 2 (PCC) upgrade pass — non-blocking, entitlement-gated dark:
        // returns .unavailable until com.apple.developer.private-cloud-compute
        // is granted, at which point it lights up with no code change. On an
        // upgrade, swap the live card in place and re-cache so the better
        // diagnosis is the one that persists.
        let judgedID = judged.id
        let baseCard = judged.card
        Task { [weak self] in
            guard let self else { return }
            if case .upgraded(let better) = await engine.pccUpgrade(
                anomaly, baselineSentence: baseline, context: context, baseCard: baseCard
            ) {
                if let i = self.anomalies.firstIndex(where: { $0.id == judgedID }) {
                    self.anomalies[i].card = better
                }
                await self.baselineStore.cacheDiagnosis(
                    CachedDiagnosis(card: better, kind: anomaly.kind, judgedByModel: true),
                    processKey: processKey, kind: anomaly.kind
                )
            }
        }
    }

    /// Notify for a freshly surfaced (high-confidence) anomaly, honoring the
    /// global alert snooze. Quiet findings never reach here by construction.
    private func notifySurfaced(_ judged: JudgedAnomaly) async {
        guard !alertsSnoozed else { return }
        await notifications.post(for: judged, conditionKey: Self.conditionKey(for: judged.anomaly))
    }

    // MARK: - Discovery (opt-in identity lookup for genuinely-unknown processes)

    /// Discovery is deduped by process LINEAGE, not by card. A process re-flags
    /// with a fresh card id on every tick, so without this each tick would kick
    /// off a new ~55s lookup for the same process — an endless spinner and a
    /// service we needlessly hammer. An in-flight lineage is reflected, never
    /// re-requested; a resolved one is reused for a TTL.
    private struct DiscoveryRecord: Equatable { var state: DiscoveryState; var at: Date }
    private var discoveryByLineage: [String: DiscoveryRecord] = [:]
    private static let discoveryTTL: TimeInterval = 6 * 60 * 60   // don't re-ask for 6h

    /// Auto-fire discovery for a genuinely-unknown card when the toggle is ON.
    /// Known/thermal/hung cards never qualify. No-op otherwise.
    private func maybeDiscover(_ judged: JudgedAnomaly) {
        guard judged.genuinelyUnknown, discoveryEnabled else { return }
        fireDiscovery(judged)
    }

    /// Per-card on-demand lookup — the toggle-OFF escape hatch. The tap itself
    /// is a consent, so it discovers regardless of the toggle (still logged) and
    /// FORCES past the lineage cache (an explicit retry).
    func lookUp(_ judged: JudgedAnomaly) {
        fireDiscovery(judged, force: true)
    }

    /// Research one unknown process. Deduped by lineage: an in-flight lookup is
    /// reflected on the card (never restarted), and a recently-resolved one is
    /// reused for a TTL. On a real miss it POSTs to /discover and polls
    /// (bounded ~60s) to a terminal state — the outcome is cached per lineage
    /// either way, so a lookup can never hang forever or re-fire every tick.
    private func fireDiscovery(_ judged: JudgedAnomaly, force: Bool = false) {
        guard force || discoveryEnabled else { return }
        if case .researching = judged.discovery { return }
        if case .sourced = judged.discovery { return }
        if case .researched = judged.discovery { return }
        let lineage = BaselineStore.key(for: judged.anomaly.identity)

        // Dedup by lineage (not card id). A forced tap always re-asks.
        if !force, let record = discoveryByLineage[lineage] {
            switch record.state {
            case .researching:
                setDiscovery(.researching, id: judged.id)   // reflect the in-flight one
                return
            case .sourced, .researched, .notRecognized:
                if Date.now.timeIntervalSince(record.at) < Self.discoveryTTL {
                    setDiscovery(record.state, id: judged.id)   // reuse the real outcome
                    return
                }
            case .failed, .none:
                // A failed lookup (timeout / unreachable) is NOT cached: a later
                // tick re-fires so a slow research (the server may still be
                // working, and now returns confident answers) eventually
                // resolves — instead of sitting on the failure for the whole TTL.
                break
            }
        }

        let id = judged.id
        let anomaly = judged.anomaly
        let baseline = judged.baselineSentence
        discoveryByLineage[lineage] = DiscoveryRecord(state: .researching, at: .now)
        setDiscovery(.researching, id: id)
        let request = DiscoveryClient.compose(anomaly: anomaly, osVersion: Self.osVersionString)

        Task { [weak self] in
            guard let self else { return }
            do {
                let submission = try await self.discoveryClient.discover(request)
                if submission.status == .complete, let assessment = submission.assessment {
                    self.applyDiscovery(assessment, id: id, baseline: baseline, anomaly: anomaly)
                    return
                }
                if submission.status == .unknown {
                    self.resolveDiscovery(.notRecognized, lineage: lineage, id: id)
                    return
                }
                guard let discoveryID = submission.discoveryID else {
                    self.resolveDiscovery(.notRecognized, lineage: lineage, id: id)
                    return
                }
                // Poll to a terminal state, long enough for research +
                // verification (~1–2 min): 3s early, then 6s (≈180s total). On
                // timeout the failure is NOT cached (see the fireDiscovery
                // dedup), so a later tick re-polls a still-working lookup instead
                // of leaving the user on "unknown" while an answer is coming.
                for attempt in 0..<40 {
                    try await Task.sleep(for: .seconds(attempt < 20 ? 3 : 6))
                    let result = try await self.discoveryClient.poll(discoveryID: discoveryID)
                    switch result.status {
                    case .complete:
                        if let assessment = result.assessment {
                            self.applyDiscovery(assessment, id: id, baseline: baseline, anomaly: anomaly)
                        } else {
                            self.resolveDiscovery(.notRecognized, lineage: lineage, id: id)
                        }
                        return
                    case .unknown:
                        self.resolveDiscovery(.notRecognized, lineage: lineage, id: id)
                        return
                    case .researching:
                        continue
                    }
                }
                self.resolveDiscovery(.failed("Lookup timed out"), lineage: lineage, id: id)
            } catch {
                self.resolveDiscovery(.failed("Couldn't reach the service"), lineage: lineage, id: id)
                print("[anomalous] discovery failed for \(anomaly.identity.executableName): \(error.localizedDescription)")
            }
        }
    }

    private func setDiscovery(_ state: DiscoveryState, id: UUID) {
        guard let i = anomalies.firstIndex(where: { $0.id == id }) else { return }
        anomalies[i].discovery = state
    }

    /// Record a terminal discovery outcome for a lineage and reflect it on the
    /// starting card AND any current card of the same lineage (the process may
    /// have re-flagged mid-research). This is what stops the endless spinner.
    private func resolveDiscovery(_ state: DiscoveryState, lineage: String, id: UUID) {
        discoveryByLineage[lineage] = DiscoveryRecord(state: state, at: .now)
        setDiscovery(state, id: id)
        for i in anomalies.indices where BaselineStore.key(for: anomalies[i].anomaly.identity) == lineage {
            if case .researching = anomalies[i].discovery { anomalies[i].discovery = state }
        }
    }

    /// Upgrade the card in place from an Anomalous-sourced assessment, keep the
    /// cited sources for the UI, and re-cache so the answer persists. Cached as
    /// model-judged so it isn't re-discovered every launch (the server also
    /// added it to the shared corpus, which grounds it properly next feed).
    private func applyDiscovery(_ assessment: DiscoveryClient.Assessment, id: UUID, baseline: String, anomaly: Anomaly) {
        guard let i = anomalies.firstIndex(where: { $0.id == id }) else { return }
        let card = assessment.card(baselineSentence: baseline)
        // A verified corpus answer is "Sourced by Anomalous"; a confident but
        // unverified research answer is shown with an honest caveat.
        let resolved: DiscoveryState = assessment.isUnverifiedResearch
            ? .researched(confidence: assessment.confidence)
            : .sourced
        anomalies[i].card = card
        anomalies[i].discovery = resolved
        anomalies[i].discoverySources = assessment.sources
        // Cache the outcome per lineage too, so re-flags before the diagnosis
        // re-cache lands don't re-trigger a lookup.
        discoveryByLineage[BaselineStore.key(for: anomaly.identity)] = DiscoveryRecord(state: resolved, at: .now)
        print("[anomalous] discovery upgraded \(anomaly.identity.executableName): \(card.whatItIs) → \(card.suggestedAction) [tier \(card.actionSafetyTier)]")
        Task { [weak self] in
            await self?.baselineStore.cacheDiagnosis(
                CachedDiagnosis(card: card, kind: anomaly.kind, judgedByModel: true),
                processKey: BaselineStore.key(for: anomaly.identity), kind: anomaly.kind
            )
        }
        publishWidgetStatus()
    }

    /// EVERY rule's verdict for one sample — the single detection chain,
    /// shared by first-detection, resurfacing, and the still-active check.
    /// All matches, not first-match: cross-dimension agreement is the
    /// confidence signal (2-of-N), and grouping needs the full set to pick a
    /// primary + alsoObserved. Ordering matters only for confidence ties:
    /// the proven long-window rules come first (the tie-break keeps them).
    /// Note the leak rule is `footprintLeakAnomaly` — the honest-memory port
    /// that falls back to RSS itself when footprint is unknown; the legacy
    /// `rssLeakAnomaly` is retired from the live chain.
    private func candidateAnomalies(for sample: ProcessSample, judgment: [BaselineMetric: SelectedBaseline]) -> [Anomaly] {
        let hist = history[sample.identity] ?? []
        var found: [Anomaly] = []
        if let a = DetectionRules.cpuTimeRatioAnomaly(sample: sample, thresholds: thresholds) { found.append(a) }
        if let a = DetectionRules.sustainedCPUAnomaly(
            history: hist,
            baseline: judgment[.cpuPercent]?.stats.median,
            robust: judgment[.cpuPercent]?.stats,
            thresholds: thresholds
        ) {
            found.append(a)
        } else if let a = DetectionRules.chronicCPUAnomaly(
            // Baseline-poisoning catch: a runaway that never spikes to 80% but
            // whose robust median is itself pathological. Only when the live
            // sustained rule didn't already fire, so we never double-flag CPU.
            robust: judgment[.cpuPercent]?.stats,
            sample: sample,
            observedSpan: hist.count >= 2 ? sample.timestamp.timeIntervalSince(hist.first!.timestamp) : nil,
            thresholds: thresholds
        ) {
            found.append(a)
        }
        if let a = DetectionRules.footprintLeakAnomaly(history: hist, baseline: judgment[.memoryMB], thresholds: thresholds) { found.append(a) }
        if let a = DetectionRules.rssCeilingAnomaly(sample: sample, thresholds: thresholds) { found.append(a) }
        if let a = hungAnomaly(for: sample) { found.append(a) }
        if let a = DetectionRules.wakeupsAnomaly(history: hist, baseline: judgment[.wakeupsPerSecond], thresholds: thresholds) { found.append(a) }
        if let a = DetectionRules.diskThrashAnomaly(history: hist, baseline: judgment[.diskBytesPerSecond], thresholds: thresholds) { found.append(a) }
        if let a = DetectionRules.gpuSaturationAnomaly(history: hist, baseline: judgment[.gpuPercent], thresholds: thresholds) { found.append(a) }
        if let a = DetectionRules.networkThroughputAnomaly(history: hist, baseline: judgment[.networkBytesPerSecond], thresholds: thresholds) { found.append(a) }
        return found
    }

    /// One tick's per-metric instantaneous observations from a sample pair —
    /// what feeds the robust/seasonal baselines. Cumulative counters become
    /// Δ/Δt; a 0 counter read means UNKNOWN (stale helper / V4 fallback), so
    /// the metric is OMITTED — never recorded as zero, never judged.
    private static func tickObservations(previous: ProcessSample, current: ProcessSample, dt: TimeInterval) -> [BaselineMetric: Double] {
        var observations: [BaselineMetric: Double] = [
            .cpuPercent: (current.cpuTimeSeconds - previous.cpuTimeSeconds) / dt * 100,
        ]
        let memory = current.physFootprintBytes != 0 ? current.physFootprintBytes : current.residentBytes
        if memory != 0 {
            observations[.memoryMB] = Double(memory) / 1_048_576
        }
        if previous.interruptWakeups != 0, current.interruptWakeups >= previous.interruptWakeups {
            observations[.wakeupsPerSecond] = Double(current.interruptWakeups - previous.interruptWakeups) / dt
        }
        let previousDisk = previous.diskBytesRead &+ previous.diskBytesWritten
        let currentDisk = current.diskBytesRead &+ current.diskBytesWritten
        if previousDisk != 0, currentDisk >= previousDisk {
            observations[.diskBytesPerSecond] = Double(currentDisk - previousDisk) / dt
        }
        // Phase 5: GPU share (Δ mach-ticks → % of one GPU-second per
        // wall-second) and network throughput — same 0-= -unknown exclusion.
        if previous.gpuTimeMachAbs != 0, current.gpuTimeMachAbs >= previous.gpuTimeMachAbs {
            observations[.gpuPercent] = Double(current.gpuTimeMachAbs - previous.gpuTimeMachAbs)
                * Collector.machTimebaseSecondsPerTick / dt * 100
        }
        let previousNet = previous.netBytesIn &+ previous.netBytesOut
        let currentNet = current.netBytesIn &+ current.netBytesOut
        if previousNet != 0, currentNet >= previousNet {
            observations[.networkBytesPerSecond] = Double(currentNet - previousNet) / dt
        }
        return observations
    }

    /// Knowledge-map causal pairs (dasd↔appstoreagent…), symmetric — the
    /// grouping predicate for same-tick cross-process insights.
    private func causallyLinked(_ a: ProcessIdentity, _ b: ProcessIdentity) -> Bool {
        guard let knowledgeMap else { return false }
        return knowledgeMap.entry(forProcessName: a.executableName)?.causallyLinked.contains(b.executableName) == true
            || knowledgeMap.entry(forProcessName: b.executableName)?.causallyLinked.contains(a.executableName) == true
    }

    /// Whether a FLAGGED process is still actively anomalous *right now* — the
    /// test that keeps a card on screen (or re-surfaces it). Confidence is NOT
    /// re-checked here, deliberately: once a card earned its place, any rule
    /// still firing holds it (re-scoring each tick would flap cards at the
    /// confidence boundary); the rules themselves recover instantaneously.
    /// The one exception is unchanged from the healing fix: the cputime_ratio
    /// rule is CUMULATIVE, so it would keep an idle-but-historically-hot
    /// process (dasd back at ~0% CPU after a 43h burn) flagged forever — it
    /// is gated on LIVE CPU so the card heals once the acute episode ends.
    /// On UNKNOWN live-CPU data we keep the card: a sampling gap must never
    /// falsely resolve a running runaway (mirrors the exit miss-grace).
    private func stillActive(_ sample: ProcessSample, candidates: [Anomaly]) -> Bool {
        if candidates.contains(where: { $0.kind != .cpuTimeRatio }) { return true }
        if candidates.contains(where: { $0.kind == .cpuTimeRatio }) {
            guard let live = DetectionRules.instantaneousCPUPercent(history: history[sample.identity] ?? []) else { return true }
            return live >= thresholds.cpuTimeRatioActivePercent
        }
        return false
    }

    /// An `app_hung` anomaly if this GUI app has been unresponsive past the
    /// threshold (blocked event loop — the inverse of the resource rules, which
    /// a runaway wouldn't trip). Reads `unresponsiveSince`, updated each tick.
    private func hungAnomaly(for sample: ProcessSample) -> Anomaly? {
        guard let since = unresponsiveSince[sample.identity] else { return nil }
        let seconds = Date.now.timeIntervalSince(since)
        return DetectionRules.hungAppAnomaly(
            identity: sample.identity,
            unresponsiveSeconds: seconds,
            magnitudeCurve: [seconds],
            detectedAt: .now
        )
    }

    /// Move a cleared anomaly into the local journal (newest first) and refresh
    /// the published list for the History/Journal view.
    private func recordResolution(_ judged: JudgedAnomaly, reason: AnomalyResolution) async {
        await journal.record(JournalEntry(
            processName: judged.anomaly.identity.executableName,
            bundleID: judged.anomaly.identity.bundleID,
            kind: judged.anomaly.kind.rawValue,
            summary: judged.card.whatItIs,
            action: judged.card.suggestedAction,
            safetyTier: judged.card.actionSafetyTier,
            judgedByModel: judged.judgedByModel,
            detectedAt: judged.anomaly.detectedAt,
            resolution: reason
        ))
        journalEntries = await journal.recent()
        // Opt-in, `.passive` only — never breaks Focus, default OFF.
        if notifyResolutions, !alertsSnoozed {
            await notifications.postResolution(
                processName: judged.anomaly.identity.executableName,
                resolutionLabel: reason.label
            )
        }
    }

    /// Re-show a flagged process's cached diagnosis if it's STILL anomalous and
    /// not already on screen — WITHOUT re-notifying (resurfacing is not a new
    /// alert). This keeps a persistent runaway visible across relaunches instead
    /// of hiding it behind "All systems nominal" while the 7-day flag holds.
    /// stillActive gates re-showing (so an idle-but-historically-hot process
    /// stays off screen); the first candidate with a cached card supplies the
    /// anomaly to rebuild it — the cache is keyed by kind, so the card shown
    /// is always the diagnosis for the condition actually firing.
    /// Returns the anomaly to keep as a QUIET finding when an acknowledgment
    /// suppressed the re-show (nil otherwise) — the caller adds it to this
    /// tick's quiet list so an acked condition stays visible in the
    /// transparency panel, never invisible.
    private func resurfaceIfStillActive(_ sample: ProcessSample, candidates: [Anomaly]) async -> Anomaly? {
        guard !anomalies.contains(where: { $0.anomaly.identity == sample.identity }) else { return nil }
        guard stillActive(sample, candidates: candidates)
        else { return nil } // flagged but no longer actively anomalous — leave it off screen
        let processKey = BaselineStore.key(for: sample.identity)
        for anomaly in candidates {
            guard let cached = await baselineStore.cachedDiagnosis(processKey: processKey, kind: anomaly.kind) else { continue }

            // Phase 4: the acknowledgment gate guards re-showing too — this is
            // the common suppression path right after "normal for me" (the
            // identity stays flagged). Re-alerts break through WITH a marker
            // and, unlike plain resurfacing, DO notify: the anti-mute
            // guarantee is a new alert by definition.
            var returnedWorse: String? = nil
            switch await ackStore.decide(
                key: Self.conditionKey(for: anomaly),
                currentMagnitude: anomaly.magnitudeCurve.last ?? 0,
                processStartAbsTime: sample.identity.startAbsTime
            ) {
            case .suppress:
                return anomaly
            case .realert(let reason):
                returnedWorse = Self.realertMarker(for: reason)
            case .notAcknowledged:
                break
            }

            var baseline = Self.observation(for: anomaly)
            if let stats = await baselineStore.baseline(forKey: processKey),
               let grounding = stats.groundingSentence(currentCPUPercent: anomaly.magnitudeCurve.last ?? 0, kind: anomaly.kind) {
                baseline = grounding + " " + baseline
            }
            var judged = JudgedAnomaly(anomaly: anomaly, card: cached.card, judgedByModel: cached.judgedByModel, baselineSentence: baseline)
            judged.returnedWorse = returnedWorse
            judged.recurrence = returnedWorse == nil ? recurrenceInfo(for: anomaly) : nil
            judged.genuinelyUnknown = Self.genuinelyUnknown(
                anomaly: anomaly,
                hasCorpusEntry: knowledgeMap?.entry(forProcessName: sample.identity.executableName) != nil,
                judgedByModel: cached.judgedByModel
            )
            anomalies.append(judged)
            if returnedWorse != nil { await notifySurfaced(judged) }
            maybeDiscover(judged)
            return nil
        }
        return nil
    }

    /// Remove a card and record how it left in the journal. User taps on the
    /// dismiss X are `.dismissed`; taking the offered action is `.actioned`.
    func dismiss(_ judged: JudgedAnomaly, reason: AnomalyResolution = .dismissed) {
        anomalies.removeAll { $0.id == judged.id }
        Task { await recordResolution(judged, reason: reason) }
        publishWidgetStatus()
    }

    /// User-initiated "Check again" (Verify): re-sample now and test the LIVE
    /// instantaneous metric — NOT the slow window/median the rules key on. If the
    /// process has calmed down (or exited), resolve the card immediately instead
    /// of waiting the ~25–90 min it takes the window to decay. Exactly what you
    /// want right after taking the recommended action.
    func verify(_ judged: JudgedAnomaly) async {
        setVerifyStatus(judged.id, .checking)
        await tick()   // fresh sample of every process
        guard anomalies.contains(where: { $0.id == judged.id }) else { return }
        let hist = history[judged.anomaly.identity] ?? []
        // A just-exited process has no fresh sample — its last reading is older
        // than a cadence interval.
        let gone = hist.last.map { Date.now.timeIntervalSince($0.timestamp) > baseInterval * 1.5 } ?? true
        if gone {
            resolveVerified(judged.id, reason: .ended)
            return
        }
        switch DetectionRules.liveConditionActive(kind: judged.anomaly.kind, history: hist, thresholds: thresholds) {
        case .some(false):
            resolveVerified(judged.id, reason: .recovered)          // calmed down → clear now
        case .some(true):
            setVerifyStatus(judged.id, .stillActive); clearVerifyStatusSoon(judged.id)
        case .none:
            setVerifyStatus(judged.id, .couldntCheck); clearVerifyStatusSoon(judged.id)
        }
    }

    private func setVerifyStatus(_ id: UUID, _ status: JudgedAnomaly.VerifyStatus?) {
        if let i = anomalies.firstIndex(where: { $0.id == id }) { anomalies[i].verifyStatus = status }
    }

    private func clearVerifyStatusSoon(_ id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            setVerifyStatus(id, nil)
        }
    }

    /// Resolve a card via Verify — the same brief "resolved" fade + journal as
    /// auto-resolution, then remove after the linger (independent of the next
    /// tick, so it clears promptly).
    private func resolveVerified(_ id: UUID, reason: AnomalyResolution) {
        guard let i = anomalies.firstIndex(where: { $0.id == id }) else { return }
        anomalies[i].verifyStatus = nil
        anomalies[i].resolvedAt = .now
        let judged = anomalies[i]
        Task { await recordResolution(judged, reason: reason) }
        Task {
            try? await Task.sleep(for: .seconds(Self.resolvedLingerSeconds))
            anomalies.removeAll { $0.id == id }
        }
        publishWidgetStatus()
    }

    // MARK: - Acknowledgment (Phase 4: "normal for me" + snooze)

    /// The condition an acknowledgment covers: process lineage · kind ·
    /// dimension. Matches the store's keying — a new kind/dimension on an
    /// acked process is a different condition and surfaces normally.
    static func conditionKey(for anomaly: Anomaly) -> String {
        AcknowledgmentStore.conditionKey(
            processKey: BaselineStore.key(for: anomaly.identity),
            kind: anomaly.kind.rawValue,
            dimension: anomaly.drivingMetric
        )
    }

    static func realertMarker(for reason: ReAlertDecision.Reason) -> String {
        switch reason {
        case .materiallyWorse: return "Returned, worse than acknowledged"
        case .newInstance: return "Returned — new process instance"
        case .snoozeExpired: return "Returned after snooze"
        }
    }

    /// "Normal for me": raise this condition's envelope to the current
    /// magnitude × the intent-heuristic multiplier — it TEACHES the
    /// acknowledgment store, it never mutes (the re-alert guarantee holds).
    func acknowledge(_ judged: JudgedAnomaly) async {
        let identity = judged.anomaly.identity
        await ackStore.loadIfNeeded()
        await ackStore.acknowledge(
            key: Self.conditionKey(for: judged.anomaly),
            magnitude: judged.anomaly.magnitudeCurve.last ?? 0,
            envelopeMultiplier: AcknowledgmentDefaults.envelopeMultiplier(
                bundleID: identity.bundleID,
                installSource: identity.installSource,
                ownerIsRoot: identity.ownerIsRoot
            ),
            processStartAbsTime: identity.startAbsTime
        )
        dismiss(judged, reason: .acknowledged)
        print("[anomalous] ACKED \(Self.conditionKey(for: judged.anomaly)) at \(judged.anomaly.magnitudeCurve.last.map { String(format: "%.1f", $0) } ?? "?")")
    }

    /// Time-boxed snooze for one condition. Re-surfaces on expiry if still
    /// active; materially-worse breaks through immediately.
    func snooze(_ judged: JudgedAnomaly, for seconds: TimeInterval) async {
        let identity = judged.anomaly.identity
        await ackStore.loadIfNeeded()
        await ackStore.snooze(
            key: Self.conditionKey(for: judged.anomaly),
            until: Date.now.addingTimeInterval(seconds),
            magnitude: judged.anomaly.magnitudeCurve.last ?? 0,
            envelopeMultiplier: AcknowledgmentDefaults.envelopeMultiplier(
                bundleID: identity.bundleID,
                installSource: identity.installSource,
                ownerIsRoot: identity.ownerIsRoot
            ),
            processStartAbsTime: identity.startAbsTime
        )
        dismiss(judged, reason: .snoozed)
    }

    /// Snooze until the end of today (local calendar).
    func snoozeToday(_ judged: JudgedAnomaly) async {
        let endOfDay = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        await snooze(judged, for: max(60, endOfDay.timeIntervalSinceNow))
    }

    /// First-touch copy for the "Normal for me" confirm — soft for a
    /// foreground user app, firm for background/root (the intent heuristic).
    func ackPrompt(for judged: JudgedAnomaly) -> String {
        let identity = judged.anomaly.identity
        return AcknowledgmentDefaults.ackPrompt(
            processName: identity.executableName,
            isUserForegroundApp: AcknowledgmentDefaults.isUserForegroundApp(
                bundleID: identity.bundleID,
                installSource: identity.installSource,
                ownerIsRoot: identity.ownerIsRoot
            )
        )
    }

    /// Condition-key entry points for notification actions and intents
    /// (they only know the key, not the JudgedAnomaly).
    func acknowledgeCondition(key: String) async {
        guard let judged = anomalies.first(where: { Self.conditionKey(for: $0.anomaly) == key }) else { return }
        await acknowledge(judged)
    }

    func snoozeCondition(key: String, seconds: TimeInterval) async {
        guard let judged = anomalies.first(where: { Self.conditionKey(for: $0.anomaly) == key }) else { return }
        await snooze(judged, for: seconds)
    }

    // MARK: - Global alert snooze (SnoozeAlertsIntent)

    /// While set, freshly surfaced anomalies still get cards (detection is
    /// never muted) but notifications stay silent — "snooze ALERTS" means
    /// exactly that.
    var alertsSnoozedUntil: Date? {
        get { UserDefaults.standard.object(forKey: "alertsSnoozedUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "alertsSnoozedUntil") }
    }
    var alertsSnoozed: Bool { (alertsSnoozedUntil ?? .distantPast) > .now }

    func snoozeAllAlerts(for seconds: TimeInterval) {
        alertsSnoozedUntil = Date.now.addingTimeInterval(seconds)
        print("[anomalous] alerts snoozed until \(alertsSnoozedUntil!.formatted())")
    }

    // MARK: - App Group status (widget) + command queue

    private var groupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SensorStatus.appGroupID)
    }

    /// The current state as the small status JSON the widget renders.
    func currentSensorStatus() -> SensorStatus {
        let active = anomalies.filter { !$0.isResolved }
        return SensorStatus(
            updatedAt: .now,
            monitoringEnabled: monitoringEnabled,
            activeCount: active.count,
            quietCount: quietFindings.count,
            watchedProcessCount: sampledProcessCount,
            topCard: active.first.map { judged in
                SensorStatus.TopCard(
                    processName: judged.anomaly.identity.executableName,
                    kind: judged.anomaly.kind.rawValue.replacingOccurrences(of: "_", with: " "),
                    summary: judged.card.whatItIs,
                    safetyTier: judged.card.actionSafetyTier,
                    conditionKey: Self.conditionKey(for: judged.anomaly),
                    returnedWorse: judged.returnedWorse != nil
                )
            }
        )
    }

    /// Write the status snapshot to the App Group and refresh widget
    /// timelines. State-driven: the widget costs nothing between writes.
    func publishWidgetStatus() {
        guard let container = groupContainerURL else { return }
        try? currentSensorStatus().write(to: SensorStatus.fileURL(in: container))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Drain and apply actions taken in the widget/Control Center process.
    ///
    /// The App Group container is user-domain and writable by any same-user
    /// process, so a queued command is treated as attacker-controlled: it must
    /// carry a valid HMAC over the shared Keychain key (forgeries and tampered
    /// fields fail), a nonce not already spent (replays fail), and its snooze
    /// is clamped to a day regardless. Only then is it executed.
    func applyWidgetCommands() async {
        guard let container = groupContainerURL else { return }
        let commands = WidgetCommand.drain(at: WidgetCommand.fileURL(in: container))
        guard !commands.isEmpty else { return }
        guard let hmacKey = SharedSecret.key(createIfMissing: true) else {
            // No key means we can't tell a real command from a forged one —
            // fail closed and drop the batch rather than trust it.
            print("[anomalous] widget command key unavailable — dropped \(commands.count) unauthenticated command(s)")
            return
        }
        for command in commands {
            guard command.isAuthentic(key: hmacKey) else {
                print("[anomalous] rejected widget command (\(command.action.rawValue)): bad or missing authentication")
                continue
            }
            guard nonceStore.claim(command.nonce) else {
                print("[anomalous] rejected widget command (\(command.action.rawValue)): replayed nonce")
                continue
            }
            switch command.action {
            case .acknowledge:
                if let conditionKey = command.conditionKey { await acknowledgeCondition(key: conditionKey) }
            case .snoozeCondition:
                if let conditionKey = command.conditionKey {
                    await snoozeCondition(key: conditionKey, seconds: command.clampedSnoozeSeconds(default: 3600))
                }
            case .snoozeAll:
                snoozeAllAlerts(for: command.clampedSnoozeSeconds(default: 3600))
            case .runScan:
                await tick()
            case .setMonitoring:
                if let enabled = command.monitoringEnabled { monitoringEnabled = enabled }
            }
        }
        publishWidgetStatus()
    }

    /// Live anomalies as App Intent entities (Siri/Spotlight/Shortcuts).
    func currentAnomalyEntities() -> [AnomalyEventEntity] {
        anomalies.filter { !$0.isResolved }.map { judged in
            AnomalyEventEntity(
                id: Self.conditionKey(for: judged.anomaly),
                processName: judged.anomaly.identity.executableName,
                kind: judged.anomaly.kind.rawValue.replacingOccurrences(of: "_", with: " "),
                summary: judged.card.whatItIs,
                safetyTier: judged.card.actionSafetyTier,
                detectedAt: judged.anomaly.detectedAt
            )
        }
    }

    /// Opt-in `.passive` notification for journal-worthy resolutions
    /// (default OFF — silence is the brand; Settings › General exposes it).
    var notifyResolutions: Bool {
        get { UserDefaults.standard.object(forKey: "notifyResolutions") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "notifyResolutions") }
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
                dismiss(judged, reason: .actioned)
                return .done
            case .failure(.notPermitted):
                // Root-owned: if the privileged helper is installed, it can
                // do the kill we can't. Otherwise fall back to the copy-paste
                // sudo command.
                if await helper.terminate(judged.anomaly.identity) {
                    dismiss(judged, reason: .actioned)
                    return .done
                }
                return .needsSudo(actuator.manualCommand(forExecutable: judged.anomaly.identity.executableName))
            case .failure(.noSuchProcess):
                dismiss(judged, reason: .actioned)
                return .gone
            case .failure(.identityChanged):
                // The pid was reused — the flagged process is already gone.
                // Never kill the stranger now holding its pid.
                dismiss(judged, reason: .actioned)
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
        } catch EscalationClient.EscalationError.insufficientBalance {
            // Not a retryable failure — the fix is to add credit.
            setEscalation(.needsCredit, for: judged)
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
    /// "3 hours" / "1 hour" / "2 days" — honours singular vs plural.
    private static func plural(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s")"
    }

    private static func observation(for anomaly: Anomaly) -> String {
        let hours = anomaly.windowSeconds / 3600
        let duration: String
        if hours >= 48 { duration = "for \(plural(Int(hours / 24), "day"))" }
        else if hours >= 1 { duration = "for \(plural(Int(hours), "hour"))" }
        else {
            // We know the exact window — say the minutes, not a vague "under an hour."
            let mins = Int(anomaly.windowSeconds / 60)
            duration = mins >= 1 ? "for \(plural(mins, "minute"))" : "for under a minute"
        }
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
        case .appHung:
            let secs = Int(anomaly.windowSeconds)
            let howLong = secs < 90 ? "for about \(plural(secs, "second"))" : "for about \(plural(secs / 60, "minute"))"
            return "It has stopped responding to input — unresponsive \(howLong)."
        case .energyWakeups:
            return "It is waking the processor about \(Int(current)) times a second \(duration) — the busy-wait pattern that quietly drains the battery."
        case .diskThrash:
            return "It has been reading and writing about \(Int(current)) MB per second of disk \(duration), far above its usual."
        case .memoryLeakFootprint:
            return "Its memory footprint has been climbing steadily \(duration), now about \(Int(current)) MB."
        case .gpuSaturation:
            return "It has been using about \(Int(current))% of the GPU \(duration), far above its usual."
        case .networkThroughput:
            return "It has been moving about \(Int(current)) MB per second over the network \(duration), far above its usual."
        }
    }

    private static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func escalationMessage(_ error: Error) -> String {
        switch error {
        case EscalationClient.EscalationError.unauthorized: return "Sign in again"
        // .insufficientBalance is handled as its own .needsCredit state (Add credit), not a retryable failure.
        case EscalationClient.EscalationError.timedOut: return "Still working — try again in a moment"
        case EscalationClient.EscalationError.server: return "The service hit a snag — try again"
        default: return "Couldn't reach the service"
        }
    }
}
