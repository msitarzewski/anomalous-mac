import AppIntents

/// Natural-phrase registration — Siri/Spotlight pick these up with zero
/// fixed-phrase training on macOS 26/27. App-target only (an appex must not
/// declare its own shortcuts provider).
struct AnomalousShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowStatusIntent(),
            phrases: [
                "Is my Mac behaving normally with \(.applicationName)",
                "Show \(.applicationName) status",
                "Is anything wrong with \(.applicationName)",
                "\(.applicationName) status",
            ],
            shortTitle: "Status",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RunScanIntent(),
            phrases: [
                "Run a scan with \(.applicationName)",
                "Scan my Mac with \(.applicationName)",
                "Check my Mac with \(.applicationName)",
            ],
            shortTitle: "Run Scan",
            systemImageName: "waveform.badge.magnifyingglass"
        )
        AppShortcut(
            intent: SnoozeAlertsIntent(),
            phrases: [
                "Snooze \(.applicationName) alerts",
                "Quiet \(.applicationName) for a while",
            ],
            shortTitle: "Snooze Alerts",
            systemImageName: "moon.zzz"
        )
    }
}
