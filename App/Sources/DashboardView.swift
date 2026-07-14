import SwiftUI
import Charts
import AnomalousCore

/// The History window's landing tab: an at-a-glance read of what Anomalous has
/// caught — how many, what types happen most, how they resolved, and which
/// processes trip the most. Non-real-time; computed from the local journal.
struct DashboardView: View {
    let appState: AppState
    /// A top-process tap jumps to the By-Process tab (wired by the window).
    var onSelectProcess: ((String) -> Void)? = nil

    @AppStorage("historyDashboardRange") private var rangeRaw = HistoryRange.month.rawValue
    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .month }
    /// Hovered/selected day on the incidents-over-time chart (macOS 26 chart
    /// selection) — drives the callout and dims the other bars.
    @State private var selectedDay: Date?
    /// Selected wedge on the resolution ring (angular selection) — drives the
    /// centre readout.
    @State private var selectedCount: Int?

    var body: some View {
        // Compute the digest ONCE per body pass — it filters + groups + sorts
        // the whole journal, so recomputing per sub-view would jank on a big
        // history. Everything below reads this one value.
        let digest = JournalAnalytics.digest(from: appState.journalEntries, range: range, now: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(digest)
                if digest.total == 0 {
                    emptyState
                } else {
                    tiles(digest)
                    incidentsOverTime(digest)
                    HStack(alignment: .top, spacing: 14) {
                        byKind(digest)
                        byResolution(digest)
                    }
                    topProcesses(digest)
                }
            }
            .padding(20)
        }
        // Content dissolves under the Liquid Glass toolbar instead of hard-clipping.
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: header + range

    private func header(_ digest: AnomalyDigest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Overview").font(.title2).fontWeight(.semibold)
                Text(subtitle(digest)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $rangeRaw) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func subtitle(_ digest: AnomalyDigest) -> String {
        digest.total == 0
            ? "No incidents in this range"
            : "\(digest.total) incident\(digest.total == 1 ? "" : "s") across \(digest.distinctProcesses) process\(digest.distinctProcesses == 1 ? "" : "es")"
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing to show yet",
            systemImage: "checkmark.seal",
            description: Text(appState.journalEntries.isEmpty
                ? "As Anomalous catches and clears anomalies, they'll be summarized here."
                : "No incidents in the selected range — try a longer one.")
        )
        .symbolEffect(.bounce, options: .nonRepeating)
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: stat tiles

    private func tiles(_ digest: AnomalyDigest) -> some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        let topType = digest.mostCommonType
        return LazyVGrid(columns: cols, spacing: 12) {
            StatTile(label: "Incidents", value: "\(digest.total)", sub: range == .unlimited ? "all time" : "last \(range.label.lowercased())")
            StatTile(label: "Processes flagged", value: "\(digest.distinctProcesses)", sub: recurringSub(digest))
            StatTile(label: "Most common", value: topType?.label ?? "—", sub: mostCommonSub(topType, total: digest.total), small: true)
            StatTile(label: "Cleared on their own", value: HistoryStyle.percent(digest.selfResolvedRate), sub: "no action needed")
        }
    }

    private func recurringSub(_ digest: AnomalyDigest) -> String {
        let recurring = digest.processes.filter { $0.count > 1 }.count
        return recurring == 0 ? "none recurring" : "\(recurring) recurring"
    }

    private func mostCommonSub(_ top: AnomalyDigest.TypeCount?, total: Int) -> String {
        guard let top, total > 0 else { return "" }
        return "\(top.count) of \(total) (\(HistoryStyle.percent(Double(top.count) / Double(total))))"
    }

    // MARK: charts

    private func incidentsOverTime(_ digest: AnomalyDigest) -> some View {
        Panel(title: "Incidents over time", subtitle: "By day") {
            Chart(digest.perDay) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Incidents", day.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
                .opacity(selectedDay == nil || isSelected(day.day) ? 1 : 0.35)
            }
            .chartXSelection(value: $selectedDay)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
            .overlay(alignment: .top) { selectionCallout(digest) }
            .animation(.easeOut(duration: 0.15), value: selectedDay)
        }
    }

    private func isSelected(_ day: Date) -> Bool {
        guard let selectedDay else { return false }
        return Calendar.current.isDate(day, inSameDayAs: selectedDay)
    }

    /// The floating "Jul 8 · 3 incidents" callout for the selected bar.
    @ViewBuilder private func selectionCallout(_ digest: AnomalyDigest) -> some View {
        if let selectedDay, let bucket = digest.perDay.first(where: { isSelected($0.day) }) {
            HStack(spacing: 5) {
                Text(selectedDay, format: .dateTime.month(.abbreviated).day())
                    .fontWeight(.semibold)
                Text("·")
                Text("\(bucket.count) incident\(bucket.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
        }
    }

    private func byKind(_ digest: AnomalyDigest) -> some View {
        let bars = digest.byType
        let maxCount = bars.map(\.count).max() ?? 1
        return Panel(title: "What's happening most", subtitle: "By type") {
            Chart(bars) { bar in
                BarMark(
                    x: .value("Count", bar.count),
                    y: .value("Type", bar.label)
                )
                .foregroundStyle(HistoryStyle.kindColor(bar.representativeKind))
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading) {
                    Text("\(bar.count)").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                }
            }
            // Headroom so the trailing count never clips at the plot edge.
            .chartXScale(domain: 0...(Double(maxCount) * 1.15))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: max(80, CGFloat(bars.count) * 30))
        }
    }

    private func byResolution(_ digest: AnomalyDigest) -> some View {
        let selected = selectedResolution(digest)
        return Panel(title: "How they resolved", subtitle: "Outcome of every incident") {
            Chart(digest.byResolution) { r in
                SectorMark(
                    angle: .value("Count", r.count),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .foregroundStyle(HistoryStyle.resolutionColor(r.resolution))
                .opacity(selected == nil || selected?.resolution == r.resolution ? 1 : 0.35)
            }
            .chartAngleSelection(value: $selectedCount)
            .frame(height: 150)
            .overlay(alignment: .center) { ringCenter(digest, selected: selected) }
            .animation(.easeOut(duration: 0.15), value: selectedCount)
            resolutionLegend(digest)
        }
    }

    @ViewBuilder private func ringCenter(_ digest: AnomalyDigest, selected: AnomalyDigest.ResolutionCount?) -> some View {
        if let selected {
            VStack(spacing: 0) {
                Text("\(selected.count)").font(.headline).monospacedDigit()
                Text(selected.resolution.label).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                Text(HistoryStyle.percent(digest.selfResolvedRate)).font(.headline)
                Text("self-cleared").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Map the ring's angular selection (a cumulative count) to its wedge.
    private func selectedResolution(_ digest: AnomalyDigest) -> AnomalyDigest.ResolutionCount? {
        guard let selectedCount else { return nil }
        var acc = 0
        for r in digest.byResolution {
            acc += r.count
            if selectedCount <= acc { return r }
        }
        return nil
    }

    private func resolutionLegend(_ digest: AnomalyDigest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(digest.byResolution) { r in
                HStack(spacing: 6) {
                    Circle().fill(HistoryStyle.resolutionColor(r.resolution)).frame(width: 8, height: 8)
                    Text(r.resolution.label).font(.caption)
                    Spacer()
                    Text("\(r.count)").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 6)
    }

    private func topProcesses(_ digest: AnomalyDigest) -> some View {
        Panel(title: "Most-flagged processes", subtitle: onSelectProcess == nil ? nil : "Select one for its full history") {
            let top = Array(digest.processes.prefix(6))
            VStack(spacing: 0) {
                ForEach(top) { proc in
                    ProcessRow(proc: proc, onSelect: onSelectProcess)
                    if proc.id != top.last?.id { Divider() }
                }
            }
        }
    }
}

// MARK: - Pieces

/// A labelled statistic tile.
private struct StatTile: View {
    let label: String
    let value: String
    var sub: String = ""
    var small: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(value)
                .font(small ? .headline : .title)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
        // Uniform card height regardless of value font (the "Most common" tile
        // uses a smaller value) — top-aligned so labels line up across the row.
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        // Same content-surface idiom as the chart panels — one card style.
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

/// A titled content panel used for each chart.
private struct Panel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.tertiary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

/// A most-flagged-process row; a button when the window can navigate to detail.
private struct ProcessRow: View {
    let proc: ProcessHistory
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(proc.displayName).font(.body).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 5) {
                    Text("last \(proc.lastResolvedAt, format: .relative(presentation: .named))")
                    if proc.count > 1 { Text("· returned \(proc.count - 1)×") }
                }
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(proc.count)").font(.callout).fontWeight(.bold).monospacedDigit()
                Text(proc.count == 1 ? "incident" : "incidents").font(.caption2).foregroundStyle(.tertiary)
            }
            if onSelect != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())

        if let onSelect {
            Button { onSelect(proc.id) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
