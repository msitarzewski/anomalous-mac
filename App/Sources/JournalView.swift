import AnomalousCore
import SwiftUI

/// Resolved-anomaly history: what Anomalous caught and how each one cleared —
/// it recovered on its own, the process ended, you handled it, or you dismissed
/// it. The active list shows only live problems; this is where they go after.
struct JournalView: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.journalEntries.isEmpty {
                ContentUnavailableView("No anomalies yet",
                    systemImage: "checkmark.seal",
                    description: Text("Anomalies the app catches will appear here once they resolve."))
            } else {
                List(appState.journalEntries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(entry.processName).font(.headline)
                            Text(entry.kind.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                            Spacer()
                            Label(entry.resolution.label, systemImage: symbol(entry.resolution))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(entry.resolution))
                                .labelStyle(.titleAndIcon)
                        }
                        Text(entry.summary)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("\(entry.resolvedAt.formatted(date: .abbreviated, time: .shortened)) · active for \(durationText(entry.duration))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    private func symbol(_ r: AnomalyResolution) -> String {
        switch r {
        case .recovered: "arrow.uturn.up.circle"
        case .ended: "stop.circle"
        case .dismissed: "xmark.circle"
        case .actioned: "checkmark.circle"
        }
    }

    private func tint(_ r: AnomalyResolution) -> Color {
        switch r {
        case .recovered, .actioned: .green
        case .ended: .secondary
        case .dismissed: .orange
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return "\(Int((seconds / 3600).rounded())) h"
    }
}
