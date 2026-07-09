import SwiftUI
import AppKit
import ServiceManagement
import AnomalousCore

private extension String {
    /// Capitalize the first character (it starts a sentence) without
    /// touching the rest — `.capitalized` would wreck acronyms/units.
    var sentenceCased: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}

struct AnomalyListView: View {
    @Bindable var appState: AppState
    let updater: UpdaterController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.anomalies.isEmpty {
                allClear
            } else {
                header
                    .padding(.bottom, 10)
                // The card stack sizes to its content (a MenuBarExtra window
                // sizes to intrinsic content — a bare ScrollView collapses to
                // zero here and clips the cards). Anomalies are rare by design,
                // so render them naturally; only scroll once the list would
                // exceed a sane height.
                let cards = VStack(spacing: 8) {
                    ForEach(appState.anomalies) { judged in
                        DiagnosisCardView(judged: judged, onDismiss: {
                            appState.dismiss(judged)
                        }, appState: appState, showGetHelp: appState.anomalies.count > 1)
                    }
                }
                if appState.anomalies.count > 4 {
                    ScrollView { cards }
                        .frame(height: 460)
                } else {
                    cards
                }
            }

            helperBanner
            Divider()
                .padding(.vertical, 10)
            footer
        }
        .padding(16)
        .animation(.snappy(duration: 0.25), value: appState.anomalies.count)
        .task {
            appState.startMonitoring()
            appState.helper.refreshStatus()
        }
        // Popover visibility drives discovery polling: a lookup in flight is
        // dropped when the popover closes (the result still lands server-side).
        .onAppear { appState.popoverIsOpen = true }
        .onDisappear { appState.popoverIsOpen = false }
    }

    /// The "super part": system-wide monitoring. Shown right in the popover
    /// (not buried in Settings) when the root helper isn't active yet —
    /// without it, Anomalous can't see root daemons like dasd.
    @ViewBuilder
    private var helperBanner: some View {
        // Nudge to enable/approve ONLY when the helper isn't set up. A helper
        // that IS installed but momentarily inactive — thermal/low-power backoff
        // skips the root probe, or a single XPC miss — must not nag "Enable
        // system-wide monitoring"; it's already enabled and the next
        // unconstrained tick re-engages it. Keying on `active` (a
        // last-sample-succeeded flag) is what made backoff look uninstalled.
        if appState.helper.status != .installed {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.top, 8)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Watch system daemons too")
                            .font(.caption.weight(.semibold))
                        Text("Right now Anomalous only sees your own apps. Enable system-wide monitoring to also watch root daemons like dasd — where the worst runaways hide.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        helperActionButton
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var helperActionButton: some View {
        switch appState.helper.status {
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 3) {
                Button("Approve in System Settings…") {
                    appState.helper.openApprovalSettings()
                }
                .controlSize(.regular)
                Text("Then turn on “Anomalous” under Login Items & Extensions.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.orange)
        default:
            Button("Enable system-wide monitoring") {
                appState.helper.install()
            }
            .controlSize(.regular)
        }
    }

    /// The brand, as a screen: silence, stated with confidence.
    private var allClear: some View {
        VStack(spacing: 10) {
            Image("StatusMark")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .foregroundStyle(.tertiary)
            Text("All systems nominal.")
                .font(.headline)
            if let at = appState.lastSampleAt {
                Text("Watching \(appState.sampledProcessCount) processes · checked \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("First check in progress…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(appState.anomalies.count == 1 ? "1 anomaly" : "\(appState.anomalies.count) anomalies")
                .font(.headline)
            Spacer()
            if let at = appState.lastSampleAt {
                Text("\(appState.sampledProcessCount) processes · \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Housekeeping lives behind the gear, menu-like per the HIG panel
    /// exception. All preferences (contribution, unknown-process lookup, the
    /// helper, notifications) live in Settings — the popover is only ever the
    /// diagnoses, so it stays quiet and uncluttered.
    private var footer: some View {
        HStack {
            // Single anomaly: hoist its Get Help into the popover footer's open
            // space (bottom-left, opposite the gear). Multiple anomalies keep
            // Get Help per-card, so this stays empty and the gear sits alone.
            if appState.anomalies.count == 1, let only = appState.anomalies.first, !only.isResolved {
                GetHelpControl(judged: only, appState: appState)
            }
            Spacer()
            Menu {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                    Divider()
                    Button("Settings…") {
                        // Bring the app forward — a menu-bar (accessory) app's
                        // Settings window otherwise opens behind everything.
                        // The argless activate() COOPERATES (macOS 14+) and can
                        // leave an accessory app behind the frontmost app, so we
                        // pass ignoringOtherApps and then force the Settings
                        // window frontmost once it exists (next runloop tick).
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async {
                            NSApp.windows
                                .first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                                .makeKeyAndOrderFront(nil)
                        }
                    }
                    .keyboardShortcut(",")
                    Button("View Send Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([appState.sendLogDirectory])
                    }
                    Button("Help & Documentation") {
                        NSWorkspace.shared.open(anomalousHelpURL("/help"))
                    }
                    Divider()
                    Button("Quit Anomalous") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("Menu: settings, send log, quit")
        }
    }
}

struct DiagnosisCardView: View {
    let judged: AppState.JudgedAnomaly
    let onDismiss: () -> Void
    var appState: AppState? = nil
    /// When there's a single anomaly, Get Help is hoisted to the popover footer
    /// (its "perfect space"), so the card suppresses its own copy. With multiple
    /// anomalies a global button can't target one card, so each keeps its own.
    var showGetHelp: Bool = true
    @State private var isHovering = false
    @State private var confirming = false
    @State private var confirmingAck = false
    @State private var sudoCommand: String? = nil
    @State private var brewService: BrewService? = nil
    @State private var brewBusy = false
    @State private var confirmingBrew = false
    @State private var confirmingForceQuit = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow                    // process name (full width) · dismiss ×
            badges                      // status · kind · re-alert pills (own row)
            anomalyHighlight            // geeky: the numbers ("is this normal?")
            plainSummary                // processed: plain "what this means"
            groupedObservations        // one-line "also:" for a grouped insight
            discoveryRow                // "Sourced by Anomalous" / looking up / Look it up
            if confirmingAck { ackConfirm }  // the "Normal for me" teaching two-step
            if expanded { identityDetail }   // deep detail on demand
            if !judged.isResolved {
                actionRow               // remediation verbs on their own row
                    .padding(.top, 4)
            }
            if case .completed(let result) = judged.escalation {
                expertResult(result)
            }
            footer                      // Get Help CTA · Details toggle · ⋯ card menu
                .padding(.top, 4)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .opacity(judged.isResolved ? 0.55 : 1)          // fading out as it resolves
        .animation(.easeOut(duration: 0.3), value: judged.isResolved)
        .contentShape(Rectangle())
        // The whole card toggles the disclosure — clicking anywhere that
        // isn't a button expands/collapses. Buttons capture their own taps.
        .onTapGesture { withAnimation(.snappy(duration: 0.28)) { expanded.toggle() } }
        .onHover { isHovering = $0 }
        .confirmationDialog(
            "Force quit “\(judged.anomaly.identity.executableName)”?",
            isPresented: $confirmingForceQuit,
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let appState { run(judged.action, appState, force: true) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Force quit ends it immediately, with no chance to save — any unsaved work is lost. A system service will usually relaunch on its own; a graceful Quit is safer whenever it works.")
        }
        .task {
            // For a Homebrew-installed process, look up its live service so
            // the card can offer the proper stop/restart remedy.
            guard let appState, judged.anomaly.identity.installSource == .homebrew else { return }
            await appState.refreshBrewServices()
            brewService = appState.brewService(for: judged)
        }
    }

    /// The card footer: the Get Help CTA on the left, and the disclosure +
    /// per-card menu on the right. Keeps the busy middle of the card for the
    /// diagnosis; everything you DO with the card lives on this one bottom row.
    private var footer: some View {
        HStack(spacing: 8) {
            if showGetHelp, !judged.isResolved, let appState {
                GetHelpControl(judged: judged, appState: appState)
            }
            Spacer(minLength: 8)
            detailsToggle
            if !judged.isResolved, appState != nil { cardMenu }
        }
    }

    /// "Details ⌄" — the disclosure, now a plain bottom toggle (replaces the
    /// old right-edge chevron rail so the title row owns the full width). The
    /// whole card is still tappable to expand.
    private var detailsToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(expanded ? "Hide details" : "Details")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide details" : "Show details")
    }

    /// The per-card overflow menu (bottom-right): the "manage this card"
    /// actions that don't warrant a always-visible button — mark normal for
    /// this Mac (the teaching two-step) and snooze.
    @ViewBuilder
    private var cardMenu: some View {
        if let appState {
            Menu {
                Button {
                    confirmingAck = true
                } label: {
                    Label("Normal for me", systemImage: "checkmark.seal")
                }
                Menu {
                    Button {
                        Task { await appState.snooze(judged, for: 3600) }
                    } label: {
                        Label("For 1 hour", systemImage: "moon.zzz")
                    }
                    Button {
                        Task { await appState.snoozeToday(judged) }
                    } label: {
                        Label("Rest of today", systemImage: "moon.zzz.fill")
                    }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Card options — accept this as normal for your Mac, or snooze it.")
            .accessibilityLabel("Card options: normal for me, snooze")
        }
    }

    /// The "Normal for me" teaching two-step: the intent-heuristic prompt + a
    /// clear confirm. Chosen from the card menu; rendered inline because the
    /// copy (what accepting means, and that it never mutes) is the point.
    @ViewBuilder
    private var ackConfirm: some View {
        if let appState {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.ackPrompt(for: judged))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        confirmingAck = false
                        Task { await appState.acknowledge(judged) }
                    } label: {
                        Label("Yes, normal for me", systemImage: "checkmark.seal")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { confirmingAck = false }
                        .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    /// The title row: the process name owns the full width (names get long —
    /// bundle-suffixed helpers especially), truncating with a hover tooltip
    /// carrying the full name; only the dismiss × (or resolved badge) shares
    /// the row, pinned right so the title truncates before it.
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(judged.anomaly.identity.executableName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(judged.anomaly.identity.executableName)
            trailingControl
        }
    }

    /// Resolved badge when the anomaly cleared on its own, else the dismiss ×.
    @ViewBuilder
    private var trailingControl: some View {
        if judged.isResolved {
            // Cleared on its own (recovered or the process exited). Brief badge,
            // then the tick removes the card and files it in the Journal.
            Label("Resolved", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .accessibilityLabel("\(judged.anomaly.identity.executableName) anomaly resolved")
        } else {
            // Always in the hierarchy for VoiceOver/keyboard (WCAG 2.1.1);
            // hover only brightens. 24×24 target (WCAG 2.5.8).
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0.6)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss — hides this card. It does NOT stop the process; use the action buttons for that.")
            .accessibilityLabel("Dismiss \(judged.anomaly.identity.executableName) anomaly")
        }
    }

    /// The badges/pills row, directly under the title: spelled-out status, the
    /// anomaly kind, and the anti-mute re-alert marker when a condition earned
    /// its way back (icon + words, never color alone).
    private var badges: some View {
        HStack(spacing: 7) {
            statusPill
            kindPill
            if let marker = judged.returnedWorse {
                Label(marker, systemImage: "arrow.uturn.up.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Re-alert: \(marker)")
            }
            Spacer(minLength: 0)
        }
    }

    /// The anomaly-kind pill (e.g. "memory.leak footprint").
    private var kindPill: some View {
        Text(judged.anomaly.kind.rawValue.replacingOccurrences(of: "_", with: " "))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
    }

    /// Spelled-out status: an icon (shape + color) plus the word in
    /// high-contrast text (WCAG 1.4.1 — never color alone) in a neutral pill.
    private var statusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: tierSymbol).imageScale(.medium).foregroundStyle(tierTint)
            Text(tierStatusWord).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(tierRole)")
    }

    /// THE highlight: what's actually abnormal, in prominent primary type.
    /// No tier dot here — a green dot next to "at 150% for 41 hours" reads as
    /// "this is fine," the opposite of the truth. The tier describes the
    /// ACTION's safety, so it lives with the action (see tierIndicator).
    private var anomalyHighlight: some View {
        Text(judged.card.isThisNormal.sentenceCased)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The processed, plain-English "what this means" — for a potentially
    /// non-technical reader. Always visible, right under the raw numbers.
    private var plainSummary: some View {
        Text(judged.card.whyItsProbablyHot.sentenceCased)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A grouped insight's correlated observations (other dimensions of the
    /// same process, or a causally-linked process) plus any machine-wide
    /// caveat — ONE terse line each, per the anti-fatigue design: related
    /// findings share this card instead of spawning their own.
    @ViewBuilder
    private var groupedObservations: some View {
        if !judged.anomaly.alsoObserved.isEmpty {
            Text("Also: \(judged.anomaly.alsoObserved.joined(separator: " · "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let context = judged.anomaly.systemContext {
            Text(context)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Discovery (opt-in identity lookup) state. Inert Text for the copy and
    /// the "Sourced by Anomalous" attribution (never color alone — an icon
    /// carries it too); cited sources are links, like the expert result. A
    /// genuinely-unknown card with discovery OFF gets a per-card "Look it up".
    /// Caption for an unverified research answer, by research confidence.
    private static func researchedCaption(_ confidence: String?) -> String {
        switch confidence?.lowercased() {
        case "high": return "Research answer — high confidence, not yet verified"
        case "medium": return "Research answer — medium confidence, not yet verified"
        default: return "Research answer — not yet verified"
        }
    }

    @ViewBuilder
    private var discoveryRow: some View {
        switch judged.discovery {
        case .researching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sourced by Anomalous — looking this up…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .sourced:
            VStack(alignment: .leading, spacing: 4) {
                Label("Sourced by Anomalous", systemImage: "globe.badge.chevron.backward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .accessibilityLabel("This answer was sourced by Anomalous")
                ForEach(judged.discoverySources, id: \.url) { src in
                    Link(destination: URL(string: src.url) ?? URL(string: "https://anomalous.bot")!) {
                        Label(src.note, systemImage: "link").font(.caption)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        case .researched(let confidence):
            VStack(alignment: .leading, spacing: 4) {
                Label(Self.researchedCaption(confidence), systemImage: "magnifyingglass.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Research answer, not yet independently verified")
                ForEach(judged.discoverySources, id: \.url) { src in
                    Link(destination: URL(string: src.url) ?? URL(string: "https://anomalous.bot")!) {
                        Label(src.note, systemImage: "link").font(.caption)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        case .notRecognized:
            Text("Anomalous couldn’t identify this one yet — treated conservatively.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .failed(let message):
            if let appState {
                InlineRetryError(message: message) { appState.lookUp(judged) }
                    .padding(.top, 2)
            }
        case .none:
            // Per-card on-demand lookup for a genuinely-unknown card when the
            // global toggle is OFF — a single-process consent (also logged).
            if judged.genuinelyUnknown, let appState, !appState.discoveryEnabled, !judged.isResolved {
                Button {
                    appState.lookUp(judged)
                } label: {
                    Label("Look it up", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .padding(.top, 2)
                .help("Send just this process's name (no paths, no personal data) to Anomalous to look up what it is. Logged in your send log.")
            }
        }
    }

    /// Disclosure: the geeky/deep detail — full identity, the recommended
    /// action in prose, and system-specific remediation. Same size as the
    /// summary and NOT indented — it reads as a continuation, not a sidebar.
    private var identityDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(judged.card.whatItIs)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(judged.card.suggestedAction)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let service = brewService {
                Text("Homebrew service — stop cleanly with `brew services stop \(service.name)`.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !judged.judgedByModel {
                if case .unavailable = AppleIntelligence.status {
                    Text("From the built-in knowledge map — turn on Apple Intelligence for richer diagnoses.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("knowledge map only").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The remediation verbs on their own row — smaller buttons now, the
    /// recommended action prominent and the rest default. Get Help and the
    /// acknowledgment verbs moved out (to the footer CTA and the ⋯ card menu),
    /// so this row is purely "act on the process."
    private var actionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if let sudoCommand {
                sudoFallback(sudoCommand)
            } else {
                primaryActions
            }
            Spacer(minLength: 0)
        }
    }

    private var tierTint: Color {
        switch judged.card.actionSafetyTier {
        case 1: return .green
        case 2: return .orange
        default: return .secondary
        }
    }
    private var tierSymbol: String {
        switch judged.card.actionSafetyTier {
        case 1: return "checkmark.circle.fill"
        case 2: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }
    /// Spelled-out status word for a non-technical reader.
    private var tierStatusWord: String {
        switch judged.card.actionSafetyTier {
        case 1: return "Safe"
        case 2: return "Caution"
        default: return "Informational"
        }
    }
    private var tierRole: String {
        switch judged.card.actionSafetyTier {
        case 1: return "Safe to act"
        case 2: return "Needs attention"
        default: return "Informational"
        }
    }

    /// Terse action verbs. A running Homebrew service prefers Stop/Restart
    /// (the correct, reversible remedy) over a raw kill. Destructive actions
    /// use role `.destructive` and a two-step confirm that also offers Force
    /// Quit (SIGKILL) — HIG: people click without reading.
    @ViewBuilder
    private var primaryActions: some View {
        if brewBusy {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").font(.callout).foregroundStyle(.secondary) }
        } else if let appState, let service = brewService {
            if confirmingBrew {
                Button("Stop", role: .destructive) { brew("stop", service, appState) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                Button("Cancel") { confirmingBrew = false }.controlSize(.small)
            } else {
                // Restart is the recommended (reversible) remedy — make it the
                // active button; Stop stays a default secondary.
                Button("Restart") { brew("restart", service, appState) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                Button("Stop") { confirmingBrew = true }.controlSize(.small)
            }
        } else {
            processActions
        }
    }

    @ViewBuilder
    private var processActions: some View {
        let action = judged.action
        if action != .explainOnly, let appState {
            if confirming && action.isDestructive {
                // Commit step: the destructive verb turns red (role); Force Quit
                // and Cancel are default secondaries beside it.
                Button(action.verb, role: .destructive) { run(action, appState, force: false) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                if action == .terminate {
                    // Force Quit is SIGKILL — no chance to save. Gate it behind
                    // its own explicit confirmation, above the graceful Quit.
                    Button("Force Quit", role: .destructive) { confirmingForceQuit = true }
                        .controlSize(.small)
                }
                Button("Cancel") { confirming = false }.controlSize(.small)
            } else {
                // Resting state: the recommended verb is the active (prominent)
                // button. It's accent-colored, not red — the red commit only
                // appears after the two-step confirm.
                Button(action.verb) {
                    if action.isDestructive { confirming = true } else { run(action, appState, force: false) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sudoFallback(_ command: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.plain).font(.caption)
        }
    }

    private func run(_ action: ProcessAction, _ appState: AppState, force: Bool) {
        confirming = false
        Task {
            if case .needsSudo(let cmd) = await appState.perform(action, on: judged, force: force) {
                sudoCommand = cmd
            }
        }
    }

    private func brew(_ action: String, _ service: BrewService, _ appState: AppState) {
        confirmingBrew = false
        brewBusy = true
        Task {
            _ = await appState.controlBrewService(action, service, dismissing: judged)
            brewBusy = false
        }
    }

    /// The expert diagnosis that came back from paid triage — the receive
    /// half of "Get help". Shows the grounded answer + cited evidence links,
    /// or an honest note when the backend couldn't reason.
    @ViewBuilder
    private func expertResult(_ result: EscalationClient.ExpertResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            Label("Expert diagnosis", systemImage: "sparkles")
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            if let note = result.note {
                Text(note).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let what = result.whatItIs {
                    Text(what).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let action = result.suggestedAction {
                    Text(action).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.evidence, id: \.url) { ev in
                    Link(destination: URL(string: ev.url) ?? URL(string: "https://anomalous.bot")!) {
                        Label(ev.note, systemImage: "link").font(.callout)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

}

/// The "Get Help" escalation control — the idle CTA (prominent, glowing) and
/// its in-flight/answered states. A standalone view so it renders either in a
/// card's footer (when there are multiple anomalies) or hoisted into the
/// popover footer when there's a single anomaly (the common case). Offered on
/// any anomaly when signed in — a non-technical user may want expert help even
/// on a "Safe" diagnosis.
struct GetHelpControl: View {
    let judged: AppState.JudgedAnomaly
    let appState: AppState

    @ViewBuilder
    var body: some View {
        if appState.canEscalate {
            switch judged.escalation {
            case .idle:
                // The CTA: an expert answer is a tap away. Prominent + a soft
                // accent glow so it reads as the invited next step.
                Button { Task { await appState.escalate(judged) } } label: {
                    Label("Get Help", systemImage: "sparkles")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .shadow(color: .accentColor.opacity(0.55), radius: 7)
                .help("Send this diagnosis for an expert answer with cited sources.")
            case .sending:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…").font(.callout).foregroundStyle(.secondary) }
            case .sent(let id):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Diagnosing · #\(id)").font(.caption).foregroundStyle(.secondary) }
            case .completed:
                Label("Expert answer ready", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
            case .failed(let message):
                InlineRetryError(message: message) { Task { await appState.escalate(judged) } }
            }
        }
    }
}

/// A compact, consistent "that didn't work — try again" affordance: a warning
/// glyph, a plain-language message, and a real Retry button (not plain text) in
/// a soft error-tinted pill. Used wherever a background operation the user
/// kicked off can fail — expert help, discovery lookup — so failures read the
/// same everywhere instead of as bare orange text.
struct InlineRetryError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.orange.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message). Retry.")
    }
}
