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
                        }, appState: appState)
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
    }

    /// The "super part": system-wide monitoring. Shown right in the popover
    /// (not buried in Settings) when the root helper isn't active yet —
    /// without it, Anomalous can't see root daemons like dasd.
    @ViewBuilder
    private var helperBanner: some View {
        if !appState.helper.active {
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

    /// Disclosure stays visible (never buried — product rule); housekeeping
    /// lives behind the ellipsis, menu-like per the HIG panel exception.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { appState.contributionEnabled },
                    set: { appState.contributionEnabled = $0 }
                )) {
                    Text("Contribute anonymous signatures")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)

                if appState.contributedCount > 0 {
                    Text("· \(appState.contributedCount) sent")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            Text("Nothing identifiable ever leaves this Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct DiagnosisCardView: View {
    let judged: AppState.JudgedAnomaly
    let onDismiss: () -> Void
    var appState: AppState? = nil
    @State private var isHovering = false
    @State private var confirming = false
    @State private var sudoCommand: String? = nil
    @State private var brewService: BrewService? = nil
    @State private var brewBusy = false
    @State private var confirmingBrew = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                header                      // name · status · kind · dismiss
                anomalyHighlight            // geeky: the numbers ("is this normal?")
                plainSummary                // processed: plain "what this means"
                if expanded { identityDetail }   // deep detail on demand
                if !judged.isResolved {
                    actionRow               // "Now what?" — terse verbs + Get help
                        .padding(.top, 6)   // breathing room above the buttons
                }
                if case .completed(let result) = judged.escalation {
                    expertResult(result)
                }
            }
            disclosureChevron               // fully right, vertically centered
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
        .task {
            // For a Homebrew-installed process, look up its live service so
            // the card can offer the proper stop/restart remedy.
            guard let appState, judged.anomaly.identity.installSource == .homebrew else { return }
            await appState.refreshBrewServices()
            brewService = appState.brewService(for: judged)
        }
    }

    /// Disclosure affordance at the card's far-right edge, vertically
    /// centered: points right when collapsed, rotates to point down when
    /// open. A real button so VoiceOver/keyboard can toggle it too.
    private var disclosureChevron: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide details" : "Show details")
    }

    /// Process name + spelled-out status + kind badge, with the disclosure
    /// chevron and dismiss on the right.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(judged.anomaly.identity.executableName).font(.headline)
            statusPill
            Text(judged.anomaly.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())

            Spacer()

            if judged.isResolved {
                // The anomaly cleared on its own (recovered or the process
                // exited). Brief resolved badge, then the tick removes the card
                // and files it in the Journal.
                Label("Resolved", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
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

    /// "Now what?" — terse action verbs on the left, Get help on the right.
    /// (Tier status is shown once, in the header.)
    private var actionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if let sudoCommand {
                sudoFallback(sudoCommand)
            } else {
                primaryActions
            }
            Spacer(minLength: 8)
            escalationControls
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
                Button("Stop", role: .destructive) { brew("stop", service, appState) }.controlSize(.regular)
                Button("Cancel") { confirmingBrew = false }.controlSize(.regular)
            } else {
                Button("Stop") { confirmingBrew = true }.controlSize(.regular)
                Button("Restart") { brew("restart", service, appState) }.controlSize(.regular)
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
                Button(action.verb, role: .destructive) { run(action, appState, force: false) }.controlSize(.regular)
                if action == .terminate {
                    Button("Force Quit", role: .destructive) { run(action, appState, force: true) }.controlSize(.regular)
                }
                Button("Cancel") { confirming = false }.controlSize(.regular)
            } else {
                Button(action.verb, role: action.isDestructive ? .destructive : nil) {
                    if action.isDestructive { confirming = true } else { run(action, appState, force: false) }
                }
                .controlSize(.regular)
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

    /// Paid triage escalation — right-aligned. Offered only for thin local
    /// diagnoses (unknown/explain-only) AND only when signed in.
    @ViewBuilder
    private var escalationControls: some View {
        // Available on any anomaly when signed in — a non-technical user may
        // want expert help even on a "safe" diagnosis. (Especially valuable
        // for unknown/explain-only cases, but never hidden on the rest.)
        if let appState, appState.canEscalate {
            switch judged.escalation {
            case .idle:
                Button("Get help") { Task { await appState.escalate(judged) } }.controlSize(.regular)
            case .sending:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…").font(.callout).foregroundStyle(.secondary) }
            case .sent(let id):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Diagnosing · #\(id)").font(.caption).foregroundStyle(.secondary) }
            case .completed:
                Label("Expert answer ready", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
            case .failed(let message):
                HStack(spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Button("Retry") { Task { await appState.escalate(judged) } }.buttonStyle(.plain).font(.caption)
                }
            }
        }
    }
}
