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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.anomalies.isEmpty {
                allClear
            } else {
                // No header/count — the cards ARE the content. The sample status
                // ("N processes · time") lives quietly in the footer instead.
                // The card stack sizes to its content (a MenuBarExtra window
                // sizes to intrinsic content — a bare ScrollView collapses to
                // zero here and clips the cards). Anomalies are rare by design,
                // so render them naturally; only scroll once the list would
                // exceed a sane height.
                // Same program can run as several processes at once (macOS spawns
                // one CGPDFService XPC helper per PDF client, etc.). Rather than
                // repeat near-identical cards, group a program's instances into
                // one disclosure card: collapsed it's a clean summary (no pid
                // clutter); expanded it reveals each instance as its own full
                // card, pid-tagged there where you actually need to tell them
                // apart. A program with a single instance renders as one card.
                let rows = Self.rows(appState.anomalies)
                let cards = VStack(spacing: 8) {
                    ForEach(rows) { row in
                        switch row.content {
                        case .single(let judged):
                            DiagnosisCardView(judged: judged, onDismiss: {
                                appState.dismiss(judged)
                            }, appState: appState, showGetHelp: true)
                        case .group(let members):
                            GroupedAnomalyCard(instances: members, appState: appState)
                        }
                    }
                }
                // Measure the natural stack height and cap it: frame =
                // min(natural, cap), so a short stack shows no empty space and a
                // tall one (even a single tall card) scrolls instead of running
                // off-screen. Only scrolls when it actually overflows.
                // Render the cards in a plain stack — NO ScrollView. The
                // MenuBarExtra window sizes to this content, so expanding a card
                // grows the WINDOW in place: the cards above stay put and it
                // animates cleanly. A ScrollView here auto-scrolled on expand
                // (yanking the cards above out of view — "scrolls up first") and
                // reflowed the panel. Anomalies are rare by design, so the stack
                // stays short; a genuinely huge stack could get tall, which the
                // detection-sensitivity work will keep in check.
                cards
            }

            helperBanner
            footer
                .padding(.top, 10)
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

    /// Housekeeping lives behind the gear, menu-like per the HIG panel
    /// exception. All preferences (contribution, unknown-process lookup, the
    /// helper, notifications) live in Settings — the popover is only ever the
    /// diagnoses, so it stays quiet and uncluttered.
    private var footer: some View {
        HStack {
            // The quiet "state of things" — how many processes were checked and
            // when — sits bottom-left, opposite the gear. Replaces the old header.
            if let at = appState.lastSampleAt {
                Text("\(appState.sampledProcessCount) processes · \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                        dismiss()
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
                        dismiss()
                    }
                    .keyboardShortcut(",")
                    Button("Anomaly History…") {
                        openWindow(id: "history")
                        NSApp.activate(ignoringOtherApps: true)
                        dismiss()
                    }
                    Button("View Send Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([appState.sendLogDirectory])
                        dismiss()
                    }
                    Button("Help & Documentation") {
                        NSWorkspace.shared.open(anomalousHelpURL("/help"))
                        dismiss()
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

    /// A row in the popover: a standalone card, or a group of a program's
    /// concurrently-active instances.
    struct Row: Identifiable {
        let id: String
        let content: Content
        enum Content {
            case single(AppState.JudgedAnomaly)
            case group([AppState.JudgedAnomaly])
        }
    }

    /// Program identity independent of the specific process instance: same
    /// executable + bundle is "the same program", even across pids/launches.
    static func programKey(_ judged: AppState.JudgedAnomaly) -> String {
        let id = judged.anomaly.identity
        return "\(id.executableName)\u{0}\(id.bundleID ?? "")"
    }

    /// Fold the (severity-ordered) anomalies into ordered rows: a program with
    /// 2+ ACTIVE instances becomes one group; everything else is a single card.
    ///
    /// Grouping is over ACTIVE (unresolved) instances only, so the instant one of
    /// a pair resolves, the other shows by itself and the count is right — no
    /// waiting out the 6s resolved-linger with a stale "(2)". A resolved instance
    /// whose program is STILL active elsewhere is dropped (its live sibling
    /// already represents the program; the faded duplicate would just flicker);
    /// a genuinely solo resolved card still fades in place.
    static func rows(_ anomalies: [AppState.JudgedAnomaly]) -> [Row] {
        var activeByKey: [String: [AppState.JudgedAnomaly]] = [:]
        for a in anomalies where !a.isResolved { activeByKey[programKey(a), default: []].append(a) }
        let activeKeys = Set(activeByKey.keys)

        var rows: [Row] = []
        var emitted = Set<String>()
        for a in anomalies {
            let key = programKey(a)
            if a.isResolved {
                if activeKeys.contains(key) { continue }
                rows.append(Row(id: "s-\(a.anomaly.identity.pid)", content: .single(a)))
            } else if let members = activeByKey[key], members.count >= 2 {
                if emitted.insert(key).inserted {
                    rows.append(Row(id: "g-\(key)", content: .group(members)))
                }
            } else {
                rows.append(Row(id: "s-\(a.anomaly.identity.pid)", content: .single(a)))
            }
        }
        return rows
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
    /// Inside a GroupedAnomalyCard the program name is already in the group
    /// header, so a member titles itself with this short ordinal ("Process 1")
    /// instead of repeating the name; the real name + pid move to the tooltip.
    var instanceLabel: String? = nil
    /// Rendered inside a GroupedAnomalyCard: drop this card's own material so it
    /// sits on the group's shared background, and defer the verdict/insight to
    /// Details so a member collapses to a single row.
    var embedded: Bool = false
    /// Whether tapping a source/expert link dismisses the enclosing surface. TRUE
    /// in the floating menu-bar popover — the panel floats high, so a link's own
    /// UI (a browser, Choosy) would open behind it; getting out of the way fixes
    /// the hand-off. FALSE in a normal Window, where `dismiss()` would close the
    /// whole window on every link tap; there we just open the URL in place.
    var dismissesOnLinkTap: Bool = true
    /// Whether a tap anywhere on the card body toggles the Details disclosure.
    /// TRUE everywhere today; a host that drives its own selection can turn it off.
    var tapToExpand: Bool = true
    @State private var isHovering = false
    @State private var confirming = false
    @State private var confirmingAck = false
    @State private var sudoCommand: String? = nil
    @State private var brewService: BrewService? = nil
    @State private var brewBusy = false
    @State private var confirmingBrew = false
    @State private var confirmingForceQuit = false
    @State private var expanded = false
    @State private var attentionHovering = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// A source link as a BUTTON, not a `Link`: the card's tap-to-expand
    /// `.onTapGesture` steals taps from a `Link` (but not from a Button/Control),
    /// so a plain `Link` here reads as unclickable. openURL does the same job.
    ///
    /// It also DISMISSES the popover on click (like "Help & Documentation"): the
    /// menu-bar window floats at a high level, so a handler that shows its own UI
    /// — a browser picker like Choosy, or just the browser — appears BEHIND the
    /// panel and can't be reached. Getting out of the way fixes every such
    /// handoff, not just this link.
    @ViewBuilder
    private func sourceLink(_ url: String, _ note: String, font: Font) -> some View {
        Button {
            openURL(URL(string: url) ?? URL(string: "https://anomalous.bot")!)
            if dismissesOnLinkTap { dismiss() }
        } label: {
            Label(note, systemImage: "link").font(font)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The single "Sourced by Anomalous" attribution shown on a discovered card.
    /// When a corpus page exists it's a link (reusing `sourceLink`'s
    /// Button+openURL+dismiss); otherwise the attribution shows with NO link.
    /// Raw per-source links are deliberately never surfaced here.
    @ViewBuilder
    private func sourcedByAnomalousLink(_ corpusURL: URL?) -> some View {
        if let corpusURL {
            sourceLink(corpusURL.absoluteString, "Sourced by Anomalous", font: .caption)
        } else {
            Label("Sourced by Anomalous", systemImage: "globe.badge.chevron.backward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sourced by Anomalous")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow                    // tier · name · ✨ · severity cue · ×
            // The plain-English OBSERVATION now leads every card — including a
            // collapsed group member — because it's the sentence that actually
            // differentiates cards (process + what's happening). The verdict is
            // demoted to the small severity cue in the title row, so a stack no
            // longer reads as five identical "This needs a look" headlines.
            glanceLine                  // the observation — the card's lead line
            groupedObservations        // one-line "also:" for a grouped insight
            verifyRow                   // transient "Check again" feedback
            if confirmingAck { ackConfirm }  // the "Normal for me" teaching two-step
            // Progressive disclosure: the collapsed card is title + observation.
            // The plain-English explanation, the identity/what-it-is, the
            // remediation buttons, the expert answer, and all source links live
            // behind Details — keeps the stack short so many cards don't run
            // off-screen.
            if expanded {
                plainSummary            // the "what this means" explanation
                identityDetail          // what it is + suggested action (prose)
                if !judged.isResolved {
                    actionRow           // remediation verbs
                        .padding(.top, 2)
                }
                // The paid expert answer (a ✨ on the title marks it), then ALL
                // source links together at the bottom — never in two places.
                if case .completed(let result) = judged.escalation {
                    expertResult(result)
                }
                discoveryRow            // "Sourced by Anomalous" + its links, last
            }
        }
        .padding(14)
        // A frosted MATERIAL, not a faint tint: it blurs whatever's behind the
        // translucent popover (a saturated wallpaper otherwise bleeds through and
        // washes out the secondary text) and turns fully opaque under Reduce
        // Transparency. Legibility over any desktop. Suppressed when embedded —
        // the group tray owns the surface, so members don't double-material.
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
            }
        }
        .opacity(judged.isResolved ? 0.55 : 1)          // fading out as it resolves
        .animation(.easeOut(duration: 0.3), value: judged.isResolved)
        .contentShape(Rectangle())
        // The whole card toggles the disclosure — clicking anywhere that
        // isn't a button expands/collapses. Buttons capture their own taps.
        // A host that owns its own selection gesture can opt out (tapToExpand).
        .onTapGesture {
            guard tapToExpand else { return }
            withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
        }
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

    /// "Details ⌄" — the disclosure toggle, revealed on hover in the title row
    /// so a resting card stays clean. The whole card is still tappable to expand.
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

    /// Transient feedback while / after "Check again" (Verify) runs. On a clear,
    /// the card resolves and disappears, so there's no lasting row for that case.
    @ViewBuilder
    private var verifyRow: some View {
        switch judged.verifyStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking if it's still a problem…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .stillActive:
            Label("Still running hot right now.", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .padding(.top, 2)
        case .couldntCheck:
            Label("Couldn't re-check just now — still keeping an eye on it.", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case nil:
            EmptyView()
        }
    }

    /// The per-card overflow menu (bottom-right): the "manage this card"
    /// actions that don't warrant a always-visible button — mark normal for
    /// this Mac (the teaching two-step) and snooze.
    @ViewBuilder
    private var cardMenu: some View {
        if let appState {
            Menu {
                Button {
                    Task { await appState.verify(judged) }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(judged.verifyStatus == .checking)
                Divider()
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
        HStack(alignment: .center, spacing: 7) {
            attentionIcon
            HStack(spacing: 5) {
                titleText
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(titleHelp)
                // The ✨ "expert answer ready" marker rides the name on every
                // card now — the old verdict headline that used to carry it is
                // gone — so a paid answer is still discoverable at a glance.
                if case .completed = judged.escalation {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                        .help("Expert answer ready — open Details to read it.")
                        .accessibilityLabel("Expert answer ready")
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Urgency now lives in the leading icon's COLOR (+ its tooltip), so
            // there's no separate text pill competing for the row.
            // Controls reveal on hover so a resting card is just icon · name —
            // a clean, scannable list. Details, ⋯ and × live here now.
            if isHovering, !judged.isResolved {
                detailsToggle
                if appState != nil { cardMenu }
            }
            trailingControl
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    /// The process name, plus a quiet trailing `pid NNNNN` only when a sibling
    /// card shares this program (see `disambiguate`). Concatenated Text so it
    /// stays one truncating line; the pid run keeps its own secondary styling.
    private var titleText: Text {
        // A group member titles itself "Process N" (the name is in the header);
        // a standalone card uses the executable name.
        Text(instanceLabel ?? judged.anomaly.identity.executableName)
    }

    /// Plain-String help (not a LocalizedStringKey so the pid isn't grouped). A
    /// member's tooltip carries the real name + pid it stands in for.
    private var titleHelp: String {
        instanceLabel != nil
            ? "\(judged.anomaly.identity.executableName) · pid \(judged.anomaly.identity.pid)"
            : judged.anomaly.identity.executableName
    }

    /// The leading marker, tinted by the level of attention the card wants:
    /// gray = nothing unusual, amber = worth a look, red = needs a look. Hover
    /// spells out the level. This IS the urgency signal — quiet by default,
    /// colored only when it matters.
    private var attentionIcon: some View {
        Image(systemName: "info.circle.fill")
            .imageScale(.large)
            .foregroundStyle(urgencyTint(judged.urgency))
            // Instant hover tip — the system .help() tooltip has a ~1s delay we
            // can't shorten, so drive a popover straight off the hover state.
            .onHover { attentionHovering = $0 }
            .popover(isPresented: $attentionHovering, arrowEdge: .bottom) {
                Text(urgencyTooltip(judged.urgency))
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: 240)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel(urgencyTooltip(judged.urgency))
    }

    /// Plain-language description of what the safety tier means, for the popover.
    private var tierDescription: String {
        switch judged.card.actionSafetyTier {
        case 1: return "Safe to act on — the offered action (Quit or Restart) is reversible, and the system brings the process back if it's needed."
        case 2: return "Act with care — stopping this could interrupt work or a running service, so read the details first."
        default: return "Explain only — there's no safe automatic action here. Anomalous tells you what's going on and leaves the decision to you."
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
                    .opacity(isHovering ? 1 : 0)   // hover-only; still in the a11y tree
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
            kindPill
            if let marker = judged.returnedWorse {
                Label(marker, systemImage: "arrow.uturn.up.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Re-alert: \(marker)")
            }
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

    /// THE lead line: the plain-English OBSERVATION — the whole-machine share
    /// ("It's using about 8% of your total processing power, ~2.4× its usual"),
    /// composed DETERMINISTICALLY (never the model's arithmetic) so the anchored
    /// number is always right. Primary type, directly under the title row: this
    /// is the sentence that differentiates one card from the next (the verdict
    /// is now the small severity cue in the title row). Exact per-core figures
    /// stay in Details.
    private var glanceLine: some View {
        Text(judged.glance.sentenceCased)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // ONE "Sourced by Anomalous" link to the public corpus page — never
            // the raw per-source links (they can be exploit advisories). nil
            // corpus_url → the attribution shows with no link.
            sourcedByAnomalousLink(judged.discoveryCorpusURL)
                .padding(.top, 2)
        case .researched(let confidence):
            VStack(alignment: .leading, spacing: 4) {
                Label(Self.researchedCaption(confidence), systemImage: "magnifyingglass.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Research answer, not yet independently verified")
                sourcedByAnomalousLink(judged.discoveryCorpusURL)
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
            if judged.genuinelyUnknown, let appState, !judged.isResolved {
                if !appState.discoveryEnabled {
                    // Toggle OFF — per-card manual lookup (a single-process consent).
                    Button {
                        appState.lookUp(judged)
                    } label: {
                        Label("Look it up", systemImage: "magnifyingglass")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                    .help("Send just this process's name (no paths, no personal data) to Anomalous to look up what it is. Logged in your send log.")
                } else if !appState.discoveryConfirmed {
                    // Toggle ON, but the FIRST automatic lookup — remind the user a
                    // name is about to leave the Mac and let them confirm the service.
                    discoveryConsentPrompt(appState)
                }
            }
        }
    }

    /// One-time reminder before the first automatic lookup: discovery is on (the
    /// onboarding default), but a process name is about to leave the Mac, so give
    /// the user a beat to confirm the service — or turn it off and keep manual
    /// per-card lookups. Shown once; after "Look it up" the flag is set and
    /// unknown processes look up automatically.
    @ViewBuilder
    private func discoveryConsentPrompt(_ appState: AppState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Anomalous doesn’t recognize this. Looking up unknown processes is on — it can send just the name (no paths, no personal data) to identify it, and every lookup is in your send log.")
            } icon: {
                Image(systemName: "magnifyingglass.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    appState.confirmDiscoveryService()
                } label: {
                    Label("Look it up", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .help("Confirm the lookup service. Unknown processes will be identified automatically from now on; change this any time in Settings.")
                Button("Turn off") {
                    appState.discoveryEnabled = false
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Turn off automatic lookups. You can still look up individual processes with the per-card button.")
            }
        }
        .padding(.top, 2)
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
            // Provenance caption — but only while the card is still a bare
            // knowledge-map entry. Once discovery has identified the process the
            // "Sourced by Anomalous" link is the provenance, so drop the
            // "knowledge map only" / AI-unavailable captions (they'd contradict it).
            if !judged.judgedByModel && !judged.discovery.identifiesProcess {
                if case .unavailable = AppleIntelligence.status {
                    Text("From the built-in knowledge map — turn on Apple Intelligence for richer diagnoses.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("knowledge map only").font(.callout).foregroundStyle(.secondary)
                }
            }
            // The model's plain "what's normal" read — one calm sentence on how
            // far from usual this is (the precise figures are in the readout
            // below). Rendered here so the generated field isn't wasted and the
            // headline verdict has its supporting "normal for it" line.
            if !judged.card.isThisNormal.isEmpty {
                Text(judged.card.isThisNormal.sentenceCased)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The exact technical readout — the numbers that used to crowd the
            // headline now live here, low-contrast and aligned: per-core CPU
            // (the figure Activity Monitor shows), memory, the baseline window,
            // the plain signal name, and where the diagnosis came from.
            detailsReadout
            // How long this has been flagged (distinct from the metric window in
            // the readout) — helps judge staleness; "Check again" re-verifies it.
            // When the process resolved and came back, show the true start of the
            // saga plus how many times it has returned, not just this episode.
            firstFlaggedLine
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        // Fade in place as the card grows — a .move(edge:.top) here made the
        // detail slide down from the top of the panel (a flash-then-settle glitch).
        .transition(.opacity)
    }

    /// One row of the technical readout.
    private struct DetailRow: Identifiable {
        // Key by the (unique) label — a fresh UUID() per render would mint new
        // identities every pass and defeat ForEach diffing.
        var id: String { label }
        let label: String
        let value: String
    }

    /// Where the diagnosis was sourced — plain provenance for the readout.
    private var detailSource: String {
        if judged.discovery.identifiesProcess { return "Sourced by Anomalous" }
        if judged.judgedByModel { return "On-device AI" }
        return "Built-in knowledge map"
    }

    /// The exact figures, keyed off the driving metric (never fabricated — a
    /// CPU anomaly shows no memory number it didn't measure). Processor stays in
    /// PER-CORE terms with the "(the figure Activity Monitor shows)" bridge, so
    /// the readout reconciles with the whole-machine glance above it.
    private var detailRows: [DetailRow] {
        let a = judged.anomaly
        let current = a.magnitudeCurve.last
        let baseline = a.baselineValue
        func whole(_ v: Double) -> String { "\(Int(v.rounded()))" }
        func metricRow(_ label: String, _ unit: String, note: String = "") -> DetailRow? {
            guard let current else { return nil }
            var value = "\(whole(current))\(unit)"
            if let baseline { value += " · normally \(whole(baseline))\(unit)" }
            if !note.isEmpty { value += "  \(note)" }
            return DetailRow(label: label, value: value)
        }

        var rows: [DetailRow] = []
        switch a.kind {
        case .sustainedCPU:
            if let r = metricRow("Processor", "% per core", note: "(the figure Activity Monitor shows)") { rows.append(r) }
        case .cpuTimeRatio:
            // A lifetime-average share of this process's OWN run time
            // (cputime ÷ uptime) — not an instantaneous per-core load, so no
            // "Activity Monitor shows" note (baseline is nil here too).
            if let r = metricRow("Processor", "%", note: "(lifetime average of its own run time, not current load)") { rows.append(r) }
        case .rssLeak, .rssCeiling, .memoryLeakFootprint:
            if let r = metricRow("Memory", " MB") { rows.append(r) }
        case .gpuSaturation:
            if let r = metricRow("GPU", "%") { rows.append(r) }
        case .energyWakeups:
            if let r = metricRow("Wakeups", "/sec") { rows.append(r) }
        case .diskThrash:
            if let r = metricRow("Disk", " MB/s") { rows.append(r) }
        case .networkThroughput:
            if let r = metricRow("Network", " MB/s") { rows.append(r) }
        case .novelProcess, .appHung:
            break   // no measured resource figure to quote honestly
        }
        rows.append(DetailRow(label: "Baseline window", value: Self.humanWindow(a.windowSeconds)))
        rows.append(DetailRow(label: "Signal", value: a.kind.plainLabel))
        rows.append(DetailRow(label: "Source", value: detailSource))
        return rows
    }

    /// The exact numbers, aligned and low-contrast — Apple-native Grid only.
    private var detailsReadout: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(detailRows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption)
        .padding(.top, 2)
    }

    /// The metric window in human units for the readout (distinct from the
    /// first-flagged clock) — "25 minutes", "3 hours", "2 days".
    static func humanWindow(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        if hours >= 48 { return "\(Int(hours / 24)) days" }
        if hours >= 1 { let h = Int(hours); return "\(h) hour\(h == 1 ? "" : "s")" }
        let mins = max(1, Int((seconds / 60).rounded()))
        return "\(mins) minute\(mins == 1 ? "" : "s")"
    }

    /// "First flagged …", enriched to "First flagged … · returned N×" when the
    /// journal shows this process+kind cleared and came back — so a flapping
    /// process reads as an ongoing saga rather than a fresh one-minute blip.
    @ViewBuilder private var firstFlaggedLine: some View {
        if let rec = judged.recurrence {
            Text("First flagged ")
                + Text(rec.firstFlaggedAt, format: .relative(presentation: .named))
                + Text(rec.scopedToToday ? " · returned \(rec.returnCount)× today"
                                         : " · returned \(rec.returnCount)×")
        } else {
            // Prefer the PERSISTED first-flag time (survives relaunch, 7-day TTL)
            // so a long-running anomaly's clock isn't reset to this session's
            // re-detection; fall back to the live detection time.
            Text("First flagged ")
                + Text(judged.firstFlaggedAt ?? judged.anomaly.detectedAt, format: .relative(presentation: .named))
        }
    }

    /// The remediation verbs on their own row — smaller buttons now, the
    /// recommended action prominent and the rest default. Get Help and the
    /// acknowledgment verbs moved out (to the footer CTA and the ⋯ card menu),
    /// so this row is purely "act on the process."
    private var actionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            // Get Help leads the action list — the magic-icon escalation, before
            // the concrete remediation verbs.
            if showGetHelp, let appState {
                GetHelpControl(judged: judged, appState: appState)
            }
            if let sudoCommand {
                sudoFallback(sudoCommand)
            } else {
                primaryActions
            }
            Spacer(minLength: 0)
            badges              // kind · re-alert pills, to the right of the actions
        }
    }

    private var tierTint: Color { anomalyTierTint(judged.card.actionSafetyTier) }
    private var tierSymbol: String { anomalyTierSymbol(judged.card.actionSafetyTier) }
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
                    .controlSize(.small).buttonStyle(.glassProminent)
                Button("Cancel") { confirmingBrew = false }.controlSize(.small).buttonStyle(.glass)
            } else {
                // Restart is the recommended (reversible) remedy — make it the
                // active button; Stop stays a default secondary.
                Button("Restart") { brew("restart", service, appState) }
                    .controlSize(.small).buttonStyle(.glassProminent)
                Button("Stop") { confirmingBrew = true }.controlSize(.small).buttonStyle(.glass)
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
                    .controlSize(.small).buttonStyle(.glassProminent)
                if action == .terminate {
                    // Force Quit is SIGKILL — no chance to save. Gate it behind
                    // its own explicit confirmation, above the graceful Quit.
                    Button("Force Quit", role: .destructive) { confirmingForceQuit = true }
                        .controlSize(.small).buttonStyle(.glass)
                }
                Button("Cancel") { confirming = false }.controlSize(.small).buttonStyle(.glass)
            } else {
                // Resting state: the recommended verb is the active (prominent)
                // button. It's accent-colored, not red — the red commit only
                // appears after the two-step confirm.
                Button(action.verb) {
                    if action.isDestructive { confirming = true } else { run(action, appState, force: false) }
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
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
    /// Render the inline markdown the expert answer emits (**bold**, [links](…)),
    /// preserving its line breaks — otherwise the asterisks show up literally.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private func expertResult(_ result: EscalationClient.ExpertResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            Label("Expert diagnosis", systemImage: "sparkles")
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            if let note = result.note {
                Text(markdown(note)).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let what = result.whatItIs {
                    Text(markdown(what)).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let action = result.suggestedAction {
                    Text(markdown(action)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.evidence, id: \.url) { ev in
                    sourceLink(ev.url, ev.note, font: .callout)
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
    @Environment(\.openSettings) private var openSettings

    @ViewBuilder
    var body: some View {
        if appState.canEscalate {
            switch judged.escalation {
            case .idle:
                // The CTA: an expert answer is a tap away. A compact green
                // magic-icon button leading the action row, with a soft glow so
                // it reads as the invited next step. The tooltip explains what
                // happens (people won't tap an unlabelled icon blindly).
                Button { Task { await appState.escalate(judged) } } label: {
                    Label("Get Help", systemImage: "sparkles").labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .tint(.green)
                .shadow(color: .green.opacity(0.55), radius: 6)
                .help("Get Help — send this diagnosis to Anomalous for an expert answer. Frontier AI researches the process and replies with cited sources you can verify. Costs a few cents from your prepaid balance; you're only charged if it finds a real answer.")
            case .sending:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…").font(.callout).foregroundStyle(.secondary) }
            case .sent(let id):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Diagnosing · #\(id)").font(.caption).foregroundStyle(.secondary) }
            case .completed:
                // Nothing here — the ✨ on the verdict and the Expert diagnosis
                // section below already say the answer's ready; a label here just
                // crowds the action row.
                EmptyView()
            case .needsCredit:
                // Not an error to retry — you're out of prepaid balance. Route
                // to the actual credit view (Settings → Account) rather than
                // offering a "Retry" that would just fail again.
                Button {
                    appState.settingsTab = .account
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows
                            .first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                            .makeKeyAndOrderFront(nil)
                    }
                } label: {
                    Label("Add credit", systemImage: "creditcard")
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .help("Opens Account, where you can top up your prepaid balance. Then tap Get Help again.")
            case .failed(let message):
                InlineRetryError(message: message) { Task { await appState.retryEscalation(judged) } }
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

// MARK: - Shared safety-tier glyphs

/// The tier icon — a glanceable status light: green shield = safe to act,
/// amber triangle = caution, gray ⓘ = explain-only. A SHIELD not a checkmark
/// (the bare checkmark.circle collided with the Resolved badge). Shared so the
/// single card and the group header never drift.
func anomalyTierSymbol(_ tier: Int) -> String {
    switch tier {
    case 1: return "checkmark.shield.fill"
    case 2: return "exclamationmark.triangle.fill"
    default: return "info.circle.fill"
    }
}

func anomalyTierTint(_ tier: Int) -> Color {
    switch tier {
    case 1: return .green
    case 2: return .orange
    default: return .secondary
    }
}

// MARK: - Severity cue (the demoted verdict)

/// The plain-English verdict, demoted from a big headline to a small, quiet
/// Apple-native tag beside the process name: an SF Symbol + short text in a
/// very subtle tinted capsule, color keyed to severity. It's a glance-level
/// severity CUE, never the focal line — the observation leads the card. Text
/// and icon always carry the meaning (never color alone), and the treatment
/// stays restrained because this app never shouts. Shared so the single card
/// and the group header render the identical tag.
struct SeverityCue: View {
    /// The exception-based urgency cue. `.none` renders NOTHING — the card's
    /// existence is already the heads-up; a badge is the exception, not the rule.
    let urgency: UrgencyCue

    var body: some View {
        switch urgency {
        case .none:
            EmptyView()
        case .worthALook, .needsALook:
            Label(text, systemImage: symbol)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
                .fixedSize()
                .accessibilityLabel(text)
        }
    }

    private var text: String {
        switch urgency {
        case .none: return ""
        case .worthALook: return "worth a look"
        case .needsALook: return "needs a look"
        }
    }

    private var symbol: String {
        switch urgency {
        case .none: return ""
        case .worthALook: return "eye"
        case .needsALook: return "exclamationmark.circle"
        }
    }

    /// Orange for "worth a look", and a MUTED red for "needs a look" —
    /// restrained, an attention cue not a siren.
    private var tint: Color {
        switch urgency {
        case .none: return .clear
        case .worthALook: return .orange
        case .needsALook: return Self.mutedRed
        }
    }

    /// A softened system red — clearly "needs attention", never an alarm red.
    static let mutedRed = Color(red: 0.80, green: 0.29, blue: 0.26)
}

/// The leading icon's color = the level of attention the card wants. Gray by
/// default (nothing unusual), amber for "worth a look", muted red for "needs a
/// look". The color is the at-a-glance signal; the tooltip spells it out.
func urgencyTint(_ urgency: UrgencyCue) -> Color {
    switch urgency {
    case .none: return .secondary
    case .worthALook: return .orange
    case .needsALook: return SeverityCue.mutedRed
    }
}

func urgencyTooltip(_ urgency: UrgencyCue) -> String {
    switch urgency {
    case .none: return "Nothing unusual — this looks roughly normal for it."
    case .worthALook: return "Worth a look — a notable change, but probably fine."
    case .needsALook: return "Needs a look — this may want your attention."
    }
}

// MARK: - Grouped instances

/// A disclosure card grouping ≥2 anomalous instances of the SAME program
/// (macOS spawns one CGPDFService helper per PDF client, one mdworker per
/// index job, …). Collapsed it's a single clean summary — no pid clutter;
/// expanded it reveals each instance as its own full card, pid-tagged there
/// (`disambiguate`) where you actually need to tell them apart. Reuses
/// DiagnosisCardView wholesale, so every per-instance capability — Get Help,
/// the action buttons, Details, discovery — stays intact.
struct GroupedAnomalyCard: View {
    @State private var attentionHovering = false
    let instances: [AppState.JudgedAnomaly]
    var appState: AppState
    /// Forwarded to each member card — FALSE in a Window so a member's source
    /// link opens in place instead of closing the window (see DiagnosisCardView).
    var dismissesOnLinkTap: Bool = true
    @State private var expanded = false

    /// The instance whose verdict and tier headline the group. Instances of one
    /// program read alike; take the first (the list is already severity-ordered).
    private var representative: AppState.JudgedAnomaly { instances[0] }
    private var name: String { representative.anomaly.identity.executableName }
    /// Every member has a paid expert answer — the group earns a ✨ too.
    private var allExpertAnswered: Bool {
        instances.allSatisfy { if case .completed = $0.escalation { return true } else { return false } }
    }

    var body: some View {
        // One shared tray (same frosted material + radius as a single card) holds
        // the header and — when expanded — every member. The members render
        // background-less (`embedded`) so it reads as items in one container, not
        // a stack of nested cards. Collapsed, the tray is indistinguishable from
        // any other card in the list.
        VStack(spacing: 0) {
            header
            if expanded {
                ForEach(Array(instances.enumerated()), id: \.element.id) { idx, judged in
                    Divider().padding(.horizontal, 10)
                    DiagnosisCardView(judged: judged, onDismiss: {
                        appState.dismiss(judged)
                    }, appState: appState, showGetHelp: true,
                    instanceLabel: "Process \(idx + 1)", embedded: true,
                    dismissesOnLinkTap: dismissesOnLinkTap)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
                // The leading marker, tinted by the group's attention level (+
                // tooltip) — aligns with single cards; urgency lives in its color.
                Image(systemName: "info.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(urgencyTint(representative.urgency))
                    .onHover { attentionHovering = $0 }
                    .popover(isPresented: $attentionHovering, arrowEdge: .bottom) {
                        Text(urgencyTooltip(representative.urgency))
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: 240)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityLabel(urgencyTooltip(representative.urgency))
                HStack(spacing: 5) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "(\(instances.count))")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    if allExpertAnswered {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.green)
                            .imageScale(.small)
                            .help("Expert answers ready — expand to read them.")
                            .accessibilityLabel("Expert answers ready")
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            // The representative instance's plain observation leads the group,
            // exactly as it leads a single card — so a collapsed group reads as
            // real content, not a clone of every other card in the stack.
            Text(representative.glance.sentenceCased)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.28)) { expanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(instances.count) instances. \(representative.verdictHeadline)")
        .accessibilityHint(expanded ? "Collapse" : "Expand to see each instance")
        .accessibilityAddTraits(.isButton)
    }
}
