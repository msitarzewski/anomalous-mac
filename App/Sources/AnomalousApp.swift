import SwiftUI
import AnomalousCore

/// Menu-bar sensor. The anti-Activity-Monitor: a quiet icon that changes
/// state only when something is actually wrong. No windows, no dock icon
/// (LSUIElement), no chat — cards and guided steps only.
@main
struct AnomalousApp: App {
    private let appState = AppState.shared

    // Sparkle auto-update. Owned for the app's lifetime; started at init so
    // background update checks run from launch. The "Check for Updates…"
    // control lives in the menu-bar window's footer menu (AnomalyListView).
    @State private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            AnomalyListView(appState: appState, updater: updater)
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
            Group {
                if appState.anomalies.isEmpty {
                    // Quiet: a TEMPLATE mark the system tints to the menu bar.
                    Image("StatusMark")
                } else {
                    // Active: a single ORIGINAL (color) image — the red spike
                    // survives (MenuBarExtra flattens a mixed template+color
                    // label to monochrome, so a ZStack overlay renders white).
                    // Light/dark bar variants live in the asset.
                    Image("StatusActive").renderingMode(.original)
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
            TabView {
                JournalView(appState: appState)
                    .tabItem { Label("Journal", systemImage: "list.bullet.clipboard") }
                HistoryView(directory: appState.sendLogDirectory)
                    .tabItem { Label("Sent", systemImage: "paperplane") }
            }
            .frame(minWidth: 480, minHeight: 380)
            .padding(.top, 4)
        }
        .windowResizability(.contentMinSize)
    }
}
