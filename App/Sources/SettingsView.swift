import SwiftUI
import ServiceManagement
import AppKit
import CryptoKit
import AnomalousCore

/// Public help & documentation lives on the marketing site (anomalous.bot),
/// independent of the dev/prod API server switch — so in-app "Learn more" links
/// always resolve for end users. Module-internal: any view can deep-link in.
func anomalousHelpURL(_ path: String = "/help") -> URL {
    URL(string: "https://anomalous.bot" + path) ?? URL(string: "https://anomalous.bot")!
}

/// Standard Settings scene (⌘,) — the HIG home for a menu-bar app's
/// configuration. Login item via ServiceManagement (framework, not HIG).
struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var inviteCode = ""
    @State private var accountEmail = ""
    @AppStorage(AppState.devServerEnabledKey) private var devServerEnabled = false
    @AppStorage(AppState.devServerURLKey) private var devServerURL = AppState.defaultDevServer
    @AppStorage(AppState.devUnlockedKey) private var devUnlocked = false
    @State private var showUnlock = false
    @State private var devPassword = ""
    @State private var unlockFailed = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            transparency.tabItem { Label("Transparency", systemImage: "eye") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        // One frame is shared across all tabs, so size it to the TALLEST —
        // Transparency, with its full "what we sample" list — so no tab
        // scrolls, and a touch wider so the prose stops wrapping so tightly.
        .frame(width: 560, height: 640)
    }

    private var account: some View {
        Form {
            if case .active(let balanceCents) = appState.accountStatus {
                gratitudeSection
                premiumSection
                balanceSection(balanceCents: balanceCents)
                Section { Button("Sign out", role: .destructive) { appState.signOutAccount() } }
            } else {
                Section {
                    Text("Detection is always free and runs entirely on your Mac. **Premium** adds expert help for the rare process the on-device model can't figure out on its own.")
                        .font(.callout)
                    Link("Accounts, tokens & Get Help", destination: anomalousHelpURL("/help/account"))
                        .font(.footnote)
                }
                premiumSection
                createAccountSection
                tokenSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await appState.verifyAccount() }
    }

    // MARK: Account sub-views

    /// The reminder that they're awesome — shown once the token verifies.
    private var gratitudeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Thank you — you're awesome.", systemImage: "heart.fill")
                    .foregroundStyle(.pink).font(.headline)
                Text("You're backing independent, privacy-first Mac software and helping keep detection free and local for everyone. That genuinely matters. 💜")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// What premium is — enumerated, in plain language. No "triage", no "paid".
    private var premiumSection: some View {
        Section("Premium — expert help when you need it") {
            premiumFeature("stethoscope", "Expert diagnosis on demand",
                "When a process stumps the on-device model, get a researched answer from frontier AI — with cited evidence you can check.")
            premiumFeature("arrow.uturn.backward", "Only pay when it helps",
                "You're charged only when you get a real diagnosis. No answer, no charge — refunded automatically.")
            premiumFeature("arrow.triangle.2.circlepath", "Gets cheaper as it grows",
                "Answers are shared and cached by condition, so a diagnosis someone already unlocked is instant — and a fraction of the price — for you.")
        }
    }

    private func premiumFeature(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func balanceSection(balanceCents: Int) -> some View {
        Section("Balance") {
            HStack {
                Text("Available")
                Spacer()
                Text(dollars(balanceCents)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
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

    /// Redeem a single-use invite code to create the account.
    private var createAccountSection: some View {
        Section("Have an invite code?") {
            TextField("Invite code", text: $inviteCode)
                .textContentType(.oneTimeCode)
            TextField("Email", text: $accountEmail)
                .textContentType(.emailAddress)
            Button {
                Task { await appState.createAccount(inviteCode: inviteCode, email: accountEmail) }
            } label: {
                HStack(spacing: 6) {
                    if appState.createInFlight { ProgressView().controlSize(.small) }
                    Text("Create Account")
                }
            }
            .disabled(appState.createInFlight || inviteCode.isEmpty || !accountEmail.contains("@"))
            if let status = appState.createStatus {
                Text(status).font(.footnote).foregroundStyle(.orange)
            }
            Text("Invite codes are single-use. Your email is only for receipts and recovering your balance — nothing else, ever.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// For users who already have a token (e.g. minted on the web dashboard).
    private var tokenSection: some View {
        Section("Already have a token?") {
            SecureField("Account token", text: Binding(
                get: { appState.accountToken },
                set: { appState.accountToken = $0 }
            ))
            Button("Verify") { Task { await appState.verifyAccount() } }
                .disabled(appState.accountToken.isEmpty)
            switch appState.accountStatus {
            case .verifying:
                Label("Verifying…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            case .invalid(let message):
                Text(message).font(.footnote).foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
    }

    private func dollars(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
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
                Link("Learn about the helper", destination: anomalousHelpURL("/help/helper"))
                    .font(.footnote)
            }

            Section("Apple Intelligence") {
                appleIntelligenceRow
                Link("How the AI tiers work", destination: anomalousHelpURL("/help/ai-tiers"))
                    .font(.footnote)
            }

            Section("Notifications") {
                Toggle("Notify when an anomaly resolves", isOn: Binding(
                    get: { appState.notifyResolutions },
                    set: { appState.notifyResolutions = $0 }
                ))
                Text("Quiet, passive notices when a journal-worthy anomaly clears — they never make a sound or break Focus. Off by default: silence is the point.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("About notifications", destination: anomalousHelpURL("/help/notifications"))
                    .font(.footnote)
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
                Link("Help", destination: anomalousHelpURL("/help"))
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

    /// "What we sample & why" — every dimension in plain language, the quiet
    /// findings the sensor chose NOT to surface, and the local-processing
    /// statement. Radical transparency as product (phase-4).
    private static let sampledDimensions: [(name: String, why: String)] = [
        ("CPU time", "How much processor a process has used, and how fast it's using it now — the classic runaway signal."),
        ("Memory footprint", "How much memory a process holds and whether it keeps climbing — the leak signal."),
        ("GPU", "How much of the graphics processor a process is using, and its GPU memory — a stuck render loop or a runaway tab."),
        ("Power & wake-ups", "How much energy a process draws and how often it jolts the CPU awake each second — the busy-wait pattern that quietly drains batteries."),
        ("Disk activity", "How much a process reads and writes per second, compared to its own usual."),
        ("Network activity", "How much a process sends and receives per second, compared to its usual. Anomalous records only how much — never where it connects."),
        ("Neural Engine", "How much Apple Neural Engine memory a process holds — for on-device AI and machine-learning work."),
        ("App responsiveness", "Whether an app has stopped responding to input (a blocked event loop)."),
        ("Process identity", "Name, bundle, version, where it was installed from, and whether it runs as root — so diagnoses name the right thing."),
        ("Machine context", "System-wide memory pressure, temperature, power draw, and load — so a victim of machine-wide duress isn't blamed as the culprit."),
    ]

    private var transparency: some View {
        Form {
            Section("What we sample & why") {
                ForEach(Self.sampledDimensions, id: \.name) { dimension in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dimension.name)
                        Text(dimension.why).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Link("What each signal means, and why", destination: anomalousHelpURL("/help/signals"))
                    .font(.footnote)
            }

            Section("Held back this check") {
                if appState.quietFindings.isEmpty {
                    Text("Nothing — no low- or medium-confidence observations right now.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("\(appState.quietFindings.count) quiet finding\(appState.quietFindings.count == 1 ? "" : "s") — observed, not surfaced") {
                        ForEach(Array(appState.quietFindings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(finding.identity.executableName)
                                Text(finding.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(finding.confidence.level.rawValue) confidence")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Findings below the surfacing bar are kept here — and acknowledged conditions inside their envelope — instead of nagging you. They surface the moment confidence rises or an envelope is exceeded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Where your data goes") {
                // OPTION-click the server value reveals the developer unlock —
                // and only option-click. A plain click does nothing, so a normal
                // user never trips a password prompt; the anchor is the server
                // URL because that's exactly what dev mode changes. The gate only
                // HIDES dev UI; the real safety is the loopback-only override.
                LabeledContent("Server", value: appState.serverDescription)
                    .contentShape(Rectangle())
                    .gesture(TapGesture().modifiers(.option).onEnded {
                        if !devUnlocked { showUnlock = true }
                    })
                Text("All detection, baselines, and judgment run on this Mac. Acknowledgments, baselines, and the journal never leave it. Only anonymous anomaly signatures are sent (if you opted in), and every byte is in the send log.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Full network disclosure (NETWORK.md)",
                     destination: URL(string: "https://github.com/msitarzewski/anomalous-mac/blob/main/NETWORK.md")!)
                Link("Privacy & what leaves your Mac", destination: anomalousHelpURL("/help/privacy"))
            }

            if showUnlock && !devUnlocked {
                Section("Developer access") {
                    SecureField("Developer password", text: $devPassword)
                        .onSubmit(attemptUnlock)
                    Button("Unlock") { attemptUnlock() }
                    if unlockFailed {
                        Text("Incorrect password.").font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            if devUnlocked {
                Section("Developer") {
                    Toggle("Use a local dev server", isOn: $devServerEnabled)
                    if devServerEnabled {
                        TextField("Dev server URL", text: $devServerURL, prompt: Text(AppState.defaultDevServer))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                        if !AppState.isAllowedOverride(devServerURL) {
                            Label("This build only accepts a localhost address.", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Text("Point the app at your own machine to test account and Get Help against a local server. Account and Get Help calls switch on the next request; quit and reopen to fully apply. A release build only accepts a localhost address.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Lock developer features", role: .destructive) {
                        devUnlocked = false
                        showUnlock = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Compare the typed password's hash against the baked blob. Never stores or
    /// recovers the password. SHA-256 of "ANOMALOUS_DEV::" + input.
    private func attemptUnlock() {
        let hash = SHA256.hash(data: Data(("ANOMALOUS_DEV::" + devPassword).utf8))
            .map { String(format: "%02x", $0) }.joined()
        if hash == AppState.devPasswordHash {
            devUnlocked = true
            showUnlock = false
            devPassword = ""
            unlockFailed = false
        } else {
            unlockFailed = true
        }
    }

    private var privacy: some View {
        Form {
            Section {
                Toggle("Contribute anonymous anomaly signatures", isOn: Binding(
                    get: { appState.contributionEnabled },
                    set: { appState.contributionEnabled = $0 }
                ))
                Text("Only anonymous signatures (process name, version, OS, anomaly shape) are sent — never paths, arguments, or anything identifiable. Every transmission is recorded in the send log.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Look up unknown processes", isOn: Binding(
                    get: { appState.discoveryEnabled },
                    set: { appState.discoveryEnabled = $0 }
                ))
                Text("When Anomalous doesn't recognize a process, send just its name (no personal data, no file paths) to our API to look up what it is. You get a real answer instead of a shrug — **Sourced by Anomalous** — and it's added to the shared knowledge map so everyone benefits. Every lookup is in your send log.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button("Reveal Send Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([appState.sendLogDirectory])
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
