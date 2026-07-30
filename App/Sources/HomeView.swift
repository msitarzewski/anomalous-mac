import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnomalousCore

/// The app's real window "home" — a Mac-app shell (sidebar + detail) like
/// Mail/Notes/Reminders. Four sections: **Now** (the LIVE cards that otherwise
/// live only in the ephemeral menu-bar popover), **History** (the resolved
/// journal, per process), **Insights** (the dashboard), and **Sent** (the
/// human-readable send log — what was actually transmitted to the server).
/// Replaces the old tabbed `HistoryWindow`; the menu bar stays the quiet default
/// and this window is a pull surface — it never auto-opens.
///
/// **One** three-column `NavigationSplitView` (never a split view nested inside a
/// split view): the sidebar is the section source list; the CONTENT column holds
/// the process list — but only for History (it collapses to nothing for the
/// single-pane sections); the DETAIL column holds the per-process drill-down for
/// History and the full pane for Now/Insights/Sent.
///
/// The app stays a quiet `.accessory` menu-bar app; this opens as an accessory
/// window (no Dock icon), like Settings and Welcome.
struct HomeView: View {
    @Bindable var appState: AppState

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case now, history, insights, sent
        var id: Self { self }
        var title: String {
            switch self {
            case .now: return "Now"
            case .history: return "History"
            case .insights: return "Insights"
            case .sent: return "Sent"
            }
        }
        var symbol: String {
            switch self {
            // Un-enclosed marks across the family — the four share one weight
            // (no lone circle enclosure on Now).
            case .now: return "bolt.horizontal"
            case .history: return "clock.arrow.circlepath"
            case .insights: return "chart.bar.xaxis"
            case .sent: return "paperplane"
            }
        }
    }

    @State private var section: Section = .now
    @State private var selectedProcessID: String?
    // History process-list controls live here (not in the content column) so they
    // survive a trip through another section and back.
    @State private var query = ""
    @State private var sort: ProcessListView.Sort = .incidents
    @State private var confirmingClear = false
    /// The Now row currently ringed by a notification deep-link. Transient: set
    /// when we scroll to a notification's card, cleared after a brief moment so
    /// the emphasis fades on its own. nil = no highlight (a normal manual open).
    @State private var highlightedRowID: String?

    /// Export/Clear act on the resolved incident journal — meaningful only on
    /// History/Insights, and only when there's something to act on.
    private var journalActionsEnabled: Bool {
        (section == .history || section == .insights) && !appState.journalEntries.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            // SIDEBAR — the section source list. Stable "Anomalous" identity;
            // per-section context rides the titlebar subtitle instead.
            List(selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        // Live anomaly count rides the Now row; a 0 badge is
                        // suppressed by the system, so the badge is quiet unless
                        // something's actually wrong.
                        .badge(item == .now ? appState.anomalies.count : 0)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .navigationTitle("Anomalous")
        } content: {
            content
        } detail: {
            detail
                // Stable window title across sections (per-section context rides
                // .navigationSubtitle, not the title).
                .navigationTitle("Anomalous")
        }
        .task { await appState.refreshJournal() }
        .toolbar {
            // Always present so the toolbar never reflows as you switch sections;
            // disabled where they don't apply (Now/Sent) or have nothing to act on.
            ToolbarItemGroup {
                Button("Export…", systemImage: "square.and.arrow.up") { exportCSV() }
                    .disabled(!journalActionsEnabled)
                    .help("Save your incident history as a CSV file")
                Button("Clear…", systemImage: "trash") { confirmingClear = true }
                    .disabled(!journalActionsEnabled)
                    .help("Erase your local incident history")
            }
        }
        .confirmationDialog("Clear anomaly history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { Task { await appState.clearJournal() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently erases your local record of resolved incidents. It can't be undone. Detection and your learned baselines are unaffected.")
        }
        // A notification deep-link names the SECTION to reveal (anomaly → Now,
        // resolution → History). Force it here — at the window level — so the
        // section's detail (and, for Now, its ScrollViewReader) is in the
        // hierarchy before it tries to scroll. Covers a fresh open (onAppear) and
        // an already-open window on another section (onChange). The actual Now
        // scroll/highlight is owned by the Now pane below; this only reveals the
        // section, then clears the hint.
        .onAppear { revealPendingSection() }
        .onChange(of: appState.pendingHomeSection) { _, _ in revealPendingSection() }
    }

    /// Honor a notification deep-link's SECTION hint: switch to the named section
    /// (Now for an anomaly, History for a resolution), then clear the hint. Runs
    /// at the window level so it works for every section — including an empty Now
    /// whose ScrollViewReader isn't in the hierarchy. Clearing keeps a plain
    /// reopen inert and lets a repeat click of the same notification re-arm (nil →
    /// section is a real change the observers can see).
    private func revealPendingSection() {
        guard let target = appState.pendingHomeSection else { return }
        section = target
        appState.pendingHomeSection = nil
    }

    // MARK: content column (process list — History only)

    @ViewBuilder
    private var content: some View {
        switch section {
        case .history:
            ProcessListView(appState: appState, selectedID: $selectedProcessID,
                            query: query, sort: $sort)
                // Stock macOS search — replaces the old hand-rolled filter field.
                // It lives on the content column (the process list moved here from
                // the sidebar in the un-nesting), so a literal `.sidebar` placement
                // no longer applies; automatic placement renders the field over
                // this column.
                .searchable(text: $query, prompt: "Filter processes")
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        default:
            // The single-pane sections have no list — collapse the middle column
            // so they read as a plain sidebar + full-width detail.
            Color.clear
                .navigationSplitViewColumnWidth(0)
        }
    }

    // MARK: detail column

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .now:
            now
        case .history:
            historyDetail
        case .insights:
            DashboardView(appState: appState, onSelectProcess: focus)
        case .sent:
            // The send log made human — the user-facing half of the two-ledger
            // transparency mechanism (auditable beats approvable). Reads the
            // byte-for-byte record of what was transmitted to the server.
            HistoryView(directory: appState.sendLogDirectory)
        }
    }

    /// History's right-hand pane: the selected process's full story, or an empty
    /// state. The list (content column) drives `selectedProcessID`.
    @ViewBuilder
    private var historyDetail: some View {
        if let proc = historyProcesses.first(where: { $0.id == selectedProcessID }) {
            ProcessDetailView(proc: proc)
        } else {
            ContentUnavailableView(
                "No history yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Processes Anomalous flags will appear here once they resolve.")
            )
        }
    }

    private var historyProcesses: [ProcessHistory] {
        JournalAnalytics.digest(from: appState.journalEntries, range: .unlimited, now: .now).processes
    }

    /// The LIVE view — the same cards as the menu-bar popover, rendered in a
    /// resizable window that supplies its own height (so the popover-only height
    /// machinery isn't needed). Stays live: it reads `appState.anomalies`
    /// (@Observable), so it tracks detections and resolutions in lockstep.
    @ViewBuilder
    private var now: some View {
        if appState.anomalies.isEmpty {
            ContentUnavailableView {
                Label("You’re all clear", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing needs your attention right now. Anomalous keeps watching quietly in the background.")
            }
            // Finding-1 guarantee: a deep-link may arrive after its card resolved
            // and was pruned (6s linger) — Now is then empty and revealPendingCard
            // (which owns the clear) isn't in the hierarchy. Clear the stale
            // selection here so it can never (a) hijack the next manual open into
            // Now, nor (b) block a repeat click of the same process (rewriting the
            // same key wouldn't fire onChange). Covers a fresh empty open
            // (onAppear) and a window that empties while shown (the last card
            // resolving flips this branch in — onChange).
            .onAppear { clearStalePendingSelection() }
            .onChange(of: appState.pendingHomeSelection) { _, _ in clearStalePendingSelection() }
        } else {
            // ScrollViewReader so a notification deep-link can scroll the target
            // card into view (Now is a ScrollView/LazyVStack, not a selectable
            // List). The card carries a transient accent ring while highlighted.
            ScrollViewReader { proxy in
                ScrollView {
                    let rows = AnomalyListView.rows(appState.anomalies)
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            card(for: row)
                                .id(row.id)
                                // Tasteful, system-styled emphasis: a 2pt accent
                                // ring matching the card's own 10pt corner, only
                                // while this row is the deep-link target. Never
                                // intercepts taps.
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .opacity(highlightedRowID == row.id ? 1 : 0)
                                        .allowsHitTesting(false)
                                }
                                .animation(.easeInOut(duration: 0.25), value: highlightedRowID)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // A fresh window open lands here with the deep-link already set;
                // an already-open window gets it via onChange. Both funnel through
                // one handler so the scroll/highlight fires exactly once per click.
                .onAppear { revealPendingCard(proxy) }
                .onChange(of: appState.pendingHomeSelection) { _, _ in revealPendingCard(proxy) }
            }
        }
    }

    /// One Now row — a standalone card or a program's grouped instances. Extracted
    /// so the row can carry the deep-link `.id` and highlight overlay uniformly.
    @ViewBuilder
    private func card(for row: AnomalyListView.Row) -> some View {
        switch row.content {
        case .single(let judged):
            DiagnosisCardView(judged: judged, onDismiss: {
                appState.dismiss(judged)
            }, appState: appState, showGetHelp: true,
            dismissesOnLinkTap: false)
        case .group(let members):
            GroupedAnomalyCard(instances: members, appState: appState,
                               dismissesOnLinkTap: false)
        }
    }

    /// Honor a notification deep-link: scroll to and ring the live card for the
    /// process the notification named, then clear the request.
    ///
    /// Edge cases, all handled here so the flow never dead-ends:
    ///  (a) the anomaly may have resolved and been pruned by click time (6s
    ///      linger) — no matching row → we just land on Now with no selection.
    ///  (b) the window may already be open — the App-scope observer refocuses it;
    ///      this runs from onChange and still drives the scroll.
    ///  (c) never fight a manual open — this only ever runs when
    ///      `pendingHomeSelection` is non-nil, which only the notification
    ///      delegate sets; we clear it immediately so a plain reopen is inert.
    private func revealPendingCard(_ proxy: ScrollViewProxy) {
        guard let key = appState.pendingHomeSelection else { return }
        let rows = AnomalyListView.rows(appState.anomalies)
        let rowID = Self.rowID(matching: key, in: rows)
        // Clear now: a normal reopen must not re-trigger, and a repeat click of
        // the same process must re-arm (nil → key is a real change the observers
        // can see).
        appState.pendingHomeSelection = nil
        guard let rowID else { return }   // edge (a): nothing live to select
        // On a fresh window open the LazyVStack may not have laid its rows out
        // yet; defer a beat so there's a target to scroll to.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(rowID, anchor: .center) }
            highlightedRowID = rowID
            try? await Task.sleep(for: .seconds(2.2))
            if highlightedRowID == rowID {
                withAnimation(.easeOut(duration: 0.4)) { highlightedRowID = nil }
            }
        }
    }

    /// Empty-Now counterpart to `revealPendingCard`: there's no live card to ring
    /// (the target already resolved and was pruned), so just drop any pending
    /// deep-link selection. This is the finding-1 guarantee that the key always
    /// returns to nil after a deep-link is handled, on the empty path too. Guarded
    /// so setting nil doesn't re-enter via its own onChange.
    private func clearStalePendingSelection() {
        if appState.pendingHomeSelection != nil { appState.pendingHomeSelection = nil }
    }

    /// Map a notification's process-lineage key (`bundleID ?? executableName`,
    /// i.e. `BaselineStore.key(for:)`) to the id of the Now row that represents
    /// it — the single card for that process, or the group card when its live
    /// instances are folded together.
    private static func rowID(matching key: String, in rows: [AnomalyListView.Row]) -> String? {
        for row in rows {
            switch row.content {
            case .single(let judged):
                if BaselineStore.key(for: judged.anomaly.identity) == key { return row.id }
            case .group(let members):
                if members.contains(where: { BaselineStore.key(for: $0.anomaly.identity) == key }) {
                    return row.id
                }
            }
        }
        return nil
    }

    /// Insights → History drill-down: focus the tapped process and switch section.
    private func focus(_ processID: String) {
        selectedProcessID = processID
        section = .history
    }

    /// Save the journal to a CSV the user chooses. Local file write only.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "anomalous-history.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = HistoryCSV.string(from: appState.journalEntries)
        do {
            try Data(csv.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t save the CSV"
            alert.runModal()
        }
    }
}

// The app stays a quiet `.accessory` (LSUIElement: menu-bar only, no Dock icon)
// at all times. The home window opens as an accessory window — like Settings and
// Welcome — brought forward via `NSApp.activate`. We deliberately do NOT toggle
// the activation policy to gain a Dock icon while the window is open: flipping
// `setActivationPolicy` makes SwiftUI's MenuBarExtra duplicate its status item (a
// ghost menu-bar icon). A real Dock presence would need an AppKit NSStatusItem
// instead of MenuBarExtra — a deliberate future rearchitecture, not a toggle.
