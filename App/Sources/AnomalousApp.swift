import SwiftUI
import AnomalousCore

/// Menu-bar sensor. The anti-Activity-Monitor: a quiet icon that changes
/// state only when something is actually wrong. No windows, no dock icon
/// (LSUIElement), no chat — cards and guided steps only.
@main
struct AnomalousApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            AnomalyListView(appState: appState)
                .frame(width: 420)
        } label: {
            // The label lives for the app's lifetime — monitoring starts at
            // launch, not on first popover open. (startMonitoring is idempotent.)
            //
            // The menu-bar mark mirrors the app icon: the bar-chart with the
            // anomaly spike + arrow. It's QUIET by default and lights up on an
            // anomaly (HIG: a menu-bar app shows nothing alarming until it must):
            //   • idle   — StatusMark alone: a TEMPLATE, so the system tints the
            //     whole mark to the menu bar's foreground (white on a dark bar,
            //     dark on a light bar). No color, no noise.
            //   • active — overlay StatusSpikeRed (ORIGINAL red) exactly over the
            //     anomaly bar + arrow, so the spike turns brand-red on any bar.
            ZStack {
                Image("StatusMark")
                if !appState.anomalies.isEmpty {
                    Image("StatusSpikeRed")
                }
            }
            .accessibilityLabel(appState.anomalies.isEmpty
                ? "Anomalous: nothing is wrong"
                : "Anomalous: \(appState.anomalies.count) anomaly\(appState.anomalies.count == 1 ? "" : "ies") detected")
            .task { appState.startMonitoring() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }

        Window("History", id: "history") {
            HistoryView(directory: appState.sendLogDirectory)
        }
        .windowResizability(.contentMinSize)
    }
}
