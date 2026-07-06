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
            StatusLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }

        // First-run "settings you should know about" — the one system approval
        // (helper) + the two privacy choices, each with a help link. Opened once
        // by StatusLabel on first launch; also reachable any time from Settings.
        Window("Welcome to Anomalous", id: "welcome") {
            OnboardingView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

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

/// The menu-bar mark — QUIET by default, red spike on an anomaly (HIG: a
/// menu-bar app shows nothing alarming until it must). Its own view so it can
/// own launch-time work: it lives for the app's lifetime, so `.task` here is
/// the reliable place to start monitoring and to present the first-run window.
private struct StatusLabel: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if appState.anomalies.isEmpty {
                // Quiet: a TEMPLATE mark the system tints to the menu bar
                // (white on a dark bar, dark on a light bar). No color, no noise.
                Image("StatusMark")
            } else {
                // Active: a single ORIGINAL (color) image — the red spike
                // survives (MenuBarExtra flattens a mixed template+color label
                // to monochrome, so a ZStack overlay would render white).
                Image("StatusActive").renderingMode(.original)
            }
        }
        .accessibilityLabel(appState.anomalies.isEmpty
            ? "Anomalous: nothing is wrong"
            : "Anomalous: \(appState.anomalies.count) anomaly\(appState.anomalies.count == 1 ? "" : "ies") detected")
        .task {
            appState.startMonitoring()   // idempotent
            if !hasCompletedOnboarding {
                openWindow(id: "welcome")
                // Accessory (LSUIElement) apps open windows behind the frontmost
                // app — bring the welcome window forward so it isn't missed.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
