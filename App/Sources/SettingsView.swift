import SwiftUI
import ServiceManagement
import AppKit
import AnomalousCore

/// Standard Settings scene (⌘,) — the HIG home for a menu-bar app's
/// configuration. Login item via ServiceManagement (framework, not HIG).
struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 300)
    }

    private var account: some View {
        Form {
            SecureField("Account token", text: Binding(
                get: { appState.accountToken },
                set: { appState.accountToken = $0 }
            ))
            Text(appState.canEscalate
                 ? "Signed in. \"Get expert help\" appears on diagnoses the on-device model can't fully resolve."
                 : "Paste your account token to enable paid expert triage for unknown or hard-to-judge processes. Detection stays free and local either way.")
                .font(.footnote).foregroundStyle(.secondary)

            if appState.canEscalate {
                Section("Balance") {
                    HStack {
                        Text("Add funds")
                        Spacer()
                        ForEach([500, 1000, 2000], id: \.self) { cents in
                            Button("$\(cents / 100)") {
                                Task { await appState.addFunds(amountCents: cents) }
                            }
                            .disabled(appState.topupInFlight)
                        }
                    }
                    if let status = appState.topupStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Opens secure Stripe checkout in your browser. You're only charged when payment completes; credit is added to your prepaid balance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }

            Section("System-wide monitoring") {
                helperRow
                Text("Without the helper, Anomalous sees only your own apps. The helper (running with your approval) lets it also watch system daemons like dasd and WindowServer — where the worst runaways hide. It only reads process CPU/memory and can stop a runaway; nothing else.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Apple Intelligence") {
                appleIntelligenceRow
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { appState.helper.refreshStatus() }
    }

    /// On-device judgment status. When Apple Intelligence is off/unavailable,
    /// cards fall back to the built-in knowledge map — this says so, and why.
    @ViewBuilder private var appleIntelligenceRow: some View {
        switch AppleIntelligence.status {
        case .available:
            Label("Available — diagnoses are composed on-device.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Unavailable", systemImage: "exclamationmark.circle")
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Text("Cards use the built-in knowledge map instead — still useful, just not model-composed. Detection and actions are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit()
                .frame(width: 72, height: 72)
            Text("Anomalous").font(.title2.weight(.semibold))
            Text(appVersion).font(.caption).foregroundStyle(.secondary)
            Text("System anomaly detection for macOS — Activity Monitor with a “So what?” and “Now what?” layer.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            HStack(spacing: 14) {
                Link("Website", destination: URL(string: "https://anomalous.bot")!)
                Text("·").foregroundStyle(.tertiary)
                Link("GitHub", destination: URL(string: "https://github.com/msitarzewski/anomalous-mac")!)
                Text("·").foregroundStyle(.tertiary)
                Link("♥ Sponsor", destination: URL(string: "https://github.com/sponsors/msitarzewski")!)
            }
            .font(.callout)
            .padding(.top, 2)

            Text("Apache-2.0 · © 2026 Michael Sitarzewski")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var helperRow: some View {
        switch appState.helper.status {
        case .installed:
            LabeledContent("Helper") {
                HStack(spacing: 6) {
                    Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Remove") { appState.helper.uninstall() }.controlSize(.small)
                }
            }
        case .requiresApproval:
            LabeledContent("Helper") {
                VStack(alignment: .trailing, spacing: 2) {
                    Button("Approve in System Settings…") {
                        appState.helper.openApprovalSettings()
                    }
                    Text("Turn on “Anomalous” under Login Items & Extensions.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .notInstalled:
            LabeledContent("Helper") {
                Button("Enable system-wide monitoring") { appState.helper.install() }
            }
        case .failed(let message):
            LabeledContent("Helper") {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var privacy: some View {
        Form {
            Toggle("Contribute anonymous anomaly signatures", isOn: Binding(
                get: { appState.contributionEnabled },
                set: { appState.contributionEnabled = $0 }
            ))
            Text("Only anonymous signatures (process name, version, OS, anomaly shape) are sent — never paths, arguments, or anything identifiable. Every transmission is recorded in the send log.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Reveal Send Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([appState.sendLogDirectory])
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
