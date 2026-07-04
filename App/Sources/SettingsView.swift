import SwiftUI
import ServiceManagement
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
        }
        .frame(width: 460, height: 280)
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

            LabeledContent("Server") {
                Text(appState.serverDescription).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { appState.helper.refreshStatus() }
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
