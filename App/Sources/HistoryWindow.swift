import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnomalousCore

/// The "Anomaly History" window: Overview (dashboard) · By Process · Sent.
/// Holds the selected tab and process so a top-process tap on the dashboard
/// jumps straight to that process's history. Reloads the journal when opened so
/// it reflects incidents resolved since the last tick. A toolbar exports the
/// history to CSV or clears it (both local-only).
struct HistoryWindow: View {
    let appState: AppState

    enum HistoryTab: Hashable { case overview, byProcess, sent }
    @State private var tab: HistoryTab = .overview
    @State private var selectedProcessID: String?
    @State private var confirmingClear = false

    var body: some View {
        // macOS 15/26 `Tab` value-builder — cleaner than `.tabItem`, and it
        // drives the native Liquid Glass tab bar.
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "chart.bar.xaxis", value: HistoryTab.overview) {
                DashboardView(appState: appState, onSelectProcess: focus)
            }
            Tab("By Process", systemImage: "square.stack.3d.up", value: HistoryTab.byProcess) {
                ProcessHistoryView(appState: appState, selectedID: $selectedProcessID)
            }
            Tab("Sent", systemImage: "paperplane", value: HistoryTab.sent) {
                HistoryView(directory: appState.sendLogDirectory)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .task { await appState.refreshJournal() }
        .toolbar {
            ToolbarItemGroup {
                Button("Export…", systemImage: "square.and.arrow.up") { exportCSV() }
                    .disabled(appState.journalEntries.isEmpty || tab == .sent)
                    .help("Save your incident history as a CSV file")
                Button("Clear…", systemImage: "trash") { confirmingClear = true }
                    .disabled(appState.journalEntries.isEmpty || tab == .sent)
                    .help("Erase your local incident history")
            }
        }
        .confirmationDialog("Clear anomaly history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { Task { await appState.clearJournal() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently erases your local record of resolved incidents. It can't be undone. Detection and your learned baselines are unaffected.")
        }
    }

    /// Dashboard → per-process drill-down: focus the process and switch tabs.
    private func focus(_ processID: String) {
        selectedProcessID = processID
        tab = .byProcess
    }

    /// Save the journal to a CSV the user chooses. Local file write only.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "anomalous-history.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = HistoryCSV.string(from: appState.journalEntries)
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
