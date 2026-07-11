import SwiftUI
import AnomalousCore

/// Shared visual language for the History window (dashboard + by-process),
/// kept consistent with the in-app card semantics: red = CPU, amber = GPU,
/// blue = memory; green = recovered, blue = handled, grey = ended, amber =
/// dismissed. One place so the dashboard and the per-process view never drift.
enum HistoryStyle {
    /// Plain, non-technical name for an anomaly kind (same wording as the
    /// notifications and the cards).
    static func kindLabel(_ raw: String) -> String {
        Anomaly.Kind(rawValue: raw)?.plainLabel ?? raw.replacingOccurrences(of: "_", with: " ")
    }

    /// Colour for a kind — matches the metric's meaning on a card.
    static func kindColor(_ raw: String) -> Color {
        switch Anomaly.Kind(rawValue: raw) {
        case .sustainedCPU, .cpuTimeRatio:                 return .red
        case .gpuSaturation:                               return .orange
        case .rssLeak, .rssCeiling, .memoryLeakFootprint:  return .blue
        case .energyWakeups:                               return .teal
        case .diskThrash:                                  return .brown
        case .networkThroughput:                           return .purple
        case .appHung:                                     return .pink
        case .novelProcess, .none:                         return .gray
        }
    }

    /// Colour for how an incident resolved (matches the card safety semantics).
    static func resolutionColor(_ r: AnomalyResolution) -> Color {
        switch r {
        case .recovered, .actioned: return .green
        case .ended, .snoozed:      return .secondary
        case .dismissed:            return .orange
        case .acknowledged:         return .blue
        }
    }

    /// SF Symbol for a resolution (incident-resolution symbols).
    static func resolutionSymbol(_ r: AnomalyResolution) -> String {
        switch r {
        case .recovered:    return "arrow.uturn.up.circle"
        case .ended:        return "stop.circle"
        case .dismissed:    return "xmark.circle"
        case .actioned:     return "checkmark.circle"
        case .acknowledged: return "checkmark.seal"
        case .snoozed:      return "moon.zzz"
        }
    }

    /// Percent string for a 0…1 rate, no decimals.
    static func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }

    /// Compact human duration (compact incident duration).
    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return "\(Int((seconds / 3600).rounded())) h"
    }
}
