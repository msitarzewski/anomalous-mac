import SwiftUI
import Charts
import AnomalousCore

/// The History window's "By Process" tab: a sidebar of every process Anomalous
/// has flagged, and — for the selected one — its whole story: a chart of its
/// incidents over time and the episode timeline. Reads the local journal; shows
/// all retained history (no range limit — per process you want the full arc).
struct ProcessHistoryView: View {
    let appState: AppState
    /// Shared with the window so the dashboard's top-process tap can select here.
    @Binding var selectedID: String?

    enum Sort: String, CaseIterable, Identifiable {
        case incidents = "Most incidents"
        case recent = "Most recent"
        case name = "Name"
        var id: String { rawValue }
    }
    @State private var sort: Sort = .incidents
    @State private var query = ""

    private var processes: [ProcessHistory] {
        JournalAnalytics.digest(from: appState.journalEntries, range: .unlimited, now: .now).processes
    }

    private var filtered: [ProcessHistory] {
        let base = query.isEmpty
            ? processes
            : processes.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .incidents: return base // already count-desc from the digest
        case .recent:    return base.sorted { $0.lastResolvedAt > $1.lastResolvedAt }
        case .name:      return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.journalEntries.count) { _, _ in ensureSelection() }
        .onChange(of: query) { _, _ in ensureSelection() }
    }

    /// Keep a valid selection: if nothing is selected, or the selected process
    /// is filtered out by the current query, jump to the first visible match.
    private func ensureSelection() {
        if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            filterField
            List(selection: $selectedID) {
                ForEach(filtered) { proc in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(proc.displayName).lineLimit(1)
                            Text("last \(proc.lastResolvedAt, format: .relative(presentation: .named))")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(proc.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(proc.id)
                }
                if filtered.isEmpty {
                    Text("No matches").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .help("Sort processes")
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
    }

    /// Always-visible type-ahead filter pinned to the top of the list — filters
    /// as you type (the macOS `.searchable` field stays hidden until you scroll).
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Filter processes", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let proc = processes.first(where: { $0.id == selectedID }) {
            ProcessDetailView(proc: proc)
        } else {
            ContentUnavailableView(
                "No history yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Processes Anomalous flags will appear here once they resolve.")
            )
        }
    }
}

/// The right-hand detail for one process: summary, a per-process incident chart,
/// and the episode timeline.
private struct ProcessDetailView: View {
    let proc: ProcessHistory
    @State private var selectedDay: Date?

    private var identityLine: String {
        proc.bundleID ?? "system process · no bundle id"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if proc.count > 1 { chart }
                episodeList
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(proc.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proc.displayName).font(.title2).fontWeight(.semibold)
            Text(identityLine).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(proc.kinds.prefix(4), id: \.self) { kind in
                    Text(HistoryStyle.kindLabel(kind))
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(HistoryStyle.kindColor(kind).opacity(0.18), in: Capsule())
                }
            }
            Text(summaryLine)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var summaryLine: String {
        var parts = ["First flagged \(relative(proc.firstDetectedAt))"]
        if proc.count > 1 { parts.append("returned \(proc.count - 1)×") }
        parts.append("\(Int((proc.selfResolvedRate * 100).rounded()))% cleared on their own")
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Incidents over time").font(.subheadline).fontWeight(.semibold)
                Spacer()
                if let selectedDay, let n = countOn(selectedDay), n > 0 {
                    Text("\(selectedDay, format: .dateTime.month(.abbreviated).day()) · \(n)")
                        .font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Chart(proc.episodes) { ep in
                BarMark(
                    x: .value("When", ep.resolvedAt, unit: .day),
                    y: .value("Incidents", 1)
                )
                .foregroundStyle(HistoryStyle.kindColor(ep.kind))
                .opacity(selectedDay == nil || Calendar.current.isDate(ep.resolvedAt, inSameDayAs: selectedDay!) ? 1 : 0.35)
            }
            .chartXSelection(value: $selectedDay)
            .chartLegend(.hidden)
            .frame(height: 120)
            .animation(.easeOut(duration: 0.15), value: selectedDay)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private func countOn(_ day: Date) -> Int? {
        proc.episodes.filter { Calendar.current.isDate($0.resolvedAt, inSameDayAs: day) }.count
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(proc.count) incident\(proc.count == 1 ? "" : "s")")
                .font(.subheadline).fontWeight(.semibold)
                .padding(.bottom, 4)
            ForEach(proc.episodes) { ep in
                EpisodeRow(entry: ep)
                if ep.id != proc.episodes.last?.id { Divider() }
            }
        }
    }
}

/// One incident in a process's timeline. Shared shape with the flat Journal.
struct EpisodeRow: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(HistoryStyle.kindLabel(entry.kind)).font(.subheadline).fontWeight(.medium)
                Spacer()
                Label(entry.resolution.label, systemImage: HistoryStyle.resolutionSymbol(entry.resolution))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HistoryStyle.resolutionColor(entry.resolution))
                    .symbolRenderingMode(.hierarchical)
                    .labelStyle(.titleAndIcon)
            }
            Text(entry.summary)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(entry.resolvedAt.formatted(date: .abbreviated, time: .shortened)) · active for \(HistoryStyle.durationText(entry.duration))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
