import SwiftUI
import AnomalousCore

/// First-run "here's what you should know" window. A menu-bar app has no
/// natural onboarding surface, so this is where we introduce — up front, once —
/// the single system approval (the root helper) and the two privacy choices
/// (anonymous contribution + unknown-process lookup), each with a link to its
/// help page, instead of burying them in a checkbox. Everything here also lives
/// in Settings; this is just the one moment we surface it deliberately.
///
/// Shown once, gated on `@AppStorage("hasCompletedOnboarding")` (see
/// AnomalousApp). Nothing here is required to proceed — the user can leave the
/// helper off and flip either toggle; the point is informed defaults, not a gate.
struct OnboardingView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var completed = false

    /// Help pages on the marketing site (anomalous.bot/help/*), deep-linked so
    /// each row points at its own explainer.
    private static let help = "https://anomalous.bot/help"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !AppleIntelligence.status.isAvailable {
                        intelligenceNotice
                        Divider()
                    }
                    helperRow
                    Divider()
                    contributionRow
                    discoveryRow
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 580)
        .task { appState.helper.refreshStatus() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Anomalous").font(.title2.weight(.bold))
                Text("Activity Monitor with a “so what?” and “now what?” — it stays quiet until something's genuinely wrong. A few things worth knowing first.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: Rows

    /// Shown only when Apple Intelligence isn't usable on this Mac (ineligible
    /// hardware, not enabled, or the model isn't ready). Anomalous still works —
    /// detection, alerts, and knowledge-map cards — so this explains, honestly,
    /// what's different and how to get the richer AI-composed diagnoses, instead
    /// of leaving a user wondering why cards look generic.
    private var intelligenceNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.purple)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence gives Anomalous its best diagnoses")
                    .font(.headline)
                if case .unavailable(let reason) = AppleIntelligence.status {
                    Text(reason)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Without it, cards come from the built-in knowledge map — still useful, just less specific. Detection, alerts, history, and everything else work exactly the same.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var helperRow: some View {
        settingRow(
            icon: "eye", tint: .blue,
            title: "System-wide monitoring",
            body: "Without it, Anomalous sees only your own apps. With one approval in System Settings — never a password — it also watches system daemons like dasd and WindowServer, where the worst runaways hide. It only reads CPU/memory and can stop a runaway; nothing else.",
            help: "\(Self.help)/helper"
        ) {
            AnyView(helperControl)
        }
    }

    private var contributionRow: some View {
        settingRow(
            icon: "dot.radiowaves.up.forward", tint: .teal,
            title: "Contribute anonymous signatures",
            body: "Help the shared knowledge map get smarter. Only the shape of an anomaly is sent — never file paths, arguments, or anything that identifies you or your Mac. Every send is in your log, byte-for-byte.",
            help: "\(Self.help)/privacy"
        ) {
            AnyView(Toggle("", isOn: Binding(
                get: { appState.contributionEnabled },
                set: { appState.contributionEnabled = $0 }
            )).labelsHidden())
        }
    }

    private var discoveryRow: some View {
        settingRow(
            icon: "magnifyingglass", tint: .indigo,
            title: "Look up unknown processes",
            body: "When Anomalous doesn't recognize a process, it sends just the name (no personal data, no paths) to look up what it is — Sourced by Anomalous — instead of showing a shrug. Every lookup is in your send log.",
            help: "\(Self.help)/discovery"
        ) {
            AnyView(Toggle("", isOn: Binding(
                get: { appState.discoveryEnabled },
                set: { appState.discoveryEnabled = $0 }
            )).labelsHidden())
        }
    }

    /// One "thing to know": icon + title + plain-language body + its control,
    /// with an optional "Learn more" deep link to the setting's help page.
    private func settingRow(
        icon: String, tint: Color, title: String, body: String, help: String?,
        @ViewBuilder control: () -> AnyView
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(tint).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let help, let url = URL(string: help) {
                    Link("Learn more", destination: url).font(.callout)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }

    @ViewBuilder private var helperControl: some View {
        switch appState.helper.status {
        case .installed:
            Label("On", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
        case .requiresApproval:
            Button("Approve…") { appState.helper.openApprovalSettings() }
        default:
            Button("Enable") { appState.helper.install() }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("You can change any of this anytime in Settings.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Get Started") {
                completed = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(16)
    }
}
