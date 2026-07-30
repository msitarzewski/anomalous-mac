import SwiftUI
import Charts
import AnomalousCore

/// The History section's CONTENT column: a stock-searchable, sortable list of
/// every process Anomalous has flagged. Selection is shared with the window so
/// the dashboard's top-process tap can drive it, and the per-process story lives
/// in `ProcessDetailView` (the detail column) — the parent (`HomeView`) composes
/// the two into one un-nested three-column split. Reads the local journal; shows
/// all retained history (no range limit — per process you want the full arc).
struct ProcessListView: View {
    let appState: AppState
    /// Shared with the window so the dashboard's top-process tap can select here.
    @Binding var selectedID: String?
    /// The window owns the search field (via `.searchable`); we read it to filter.
    let query: String
    /// Owned by the window so the choice survives leaving History and coming back.
    @Binding var sort: Sort

    enum Sort: String, CaseIterable, Identifiable {
        case incidents = "Most incidents"
        case recent = "Most recent"
        case name = "Name"
        var id: String { rawValue }
    }

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
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.journalEntries.count) { _, _ in ensureSelection() }
        .onChange(of: query) { _, _ in ensureSelection() }
        .onChange(of: sort) { _, _ in ensureSelection() }
    }

    /// Keep a valid selection: if nothing is selected, or the selected process
    /// is filtered out by the current query, jump to the first visible match.
    private func ensureSelection() {
        if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
        }
    }
}

/// The right-hand detail for one process: summary, a per-process incident chart,
/// and the episode timeline. Composed by `HomeView` as the History detail column.
struct ProcessDetailView: View {
    let proc: ProcessHistory
    @State private var selectedDay: Date?

    private var identityLine: String {
        proc.bundleID ?? "system process · no bundle id"
    }

    /// Kinds collapsed to distinct DISPLAY labels (first raw kind kept for its
    /// colour), so kinds sharing a label don't render duplicate pills.
    private var distinctTypePills: [(label: String, kind: String)] {
        var seen = Set<String>()
        return proc.kinds.compactMap { kind in
            let label = HistoryStyle.kindLabel(kind)
            return seen.insert(label).inserted ? (label, kind) : nil
        }
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
        // The precise identifier rides the titlebar subtitle; the friendly name
        // stays big in the header below.
        .navigationSubtitle(identityLine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proc.displayName).font(.title2).fontWeight(.semibold)
            HStack(spacing: 6) {
                // Dedupe by DISPLAY label: several raw kinds share one label
                // (sustained_cpu + cputime_ratio → "High CPU"), which otherwise
                // renders the same pill twice.
                ForEach(distinctTypePills.prefix(4), id: \.label) { pill in
                    Text(pill.label)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(HistoryStyle.kindColor(pill.kind).opacity(0.18), in: Capsule())
                }
            }
            Text(summaryLine)
                .font(.body).foregroundStyle(.secondary)
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
                Text(HistoryStyle.kindLabel(entry.kind)).font(.body).fontWeight(.medium)
                Spacer()
                Label(entry.resolution.label, systemImage: HistoryStyle.resolutionSymbol(entry.resolution))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HistoryStyle.resolutionColor(entry.resolution))
                    .symbolRenderingMode(.hierarchical)
                    .labelStyle(.titleAndIcon)
            }
            Text(entry.summary)
                .font(.body).foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(entry.resolvedAt.formatted(date: .abbreviated, time: .shortened)) · active for \(HistoryStyle.durationText(entry.duration))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
