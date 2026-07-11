import Foundation
import AppKit
import UserNotifications
import AnomalousCore

/// Diagnosis-card notifications, bound by memory-bank/design-guidelines.md
/// and phase-4's discipline:
///   • Authorization is requested LAZILY — at the first surfaced anomaly,
///     never at launch (the quiet product must not open with a permission ask).
///   • A surfaced anomaly is `.timeSensitive` — by construction it already
///     passed Phase 2's high-confidence gate ("confirmed"), which is exactly
///     the act-soon relevance Time Sensitive is reserved for. Requires the
///     time-sensitive entitlement on the app.
///   • Medium/low findings (quietFindings) NEVER notify — they never reach
///     this class; AppState only posts for surfaced cards.
///   • Resolutions are `.passive`, opt-in, default OFF.
///   • One thread per process lineage so bursts collapse to one summary.
///   • Actions: Investigate (foregrounds the app), Snooze 1h, Normal for me —
///     backed by the same acknowledgment paths as the card buttons. No kill
///     action in a notification (destructive needs the card's confirm step).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let anomalyCategoryID = "ANOMALY"
    static let investigateActionID = "INVESTIGATE"
    static let snoozeActionID = "SNOOZE_1H"
    static let normalActionID = "NORMAL_FOR_ME"

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    /// Wired by AppState: condition-key callbacks into the acknowledgment
    /// paths (kept as closures so this class stays a thin adapter).
    var onSnoozeCondition: ((String) -> Void)?
    var onAcknowledgeCondition: ((String) -> Void)?

    override init() {
        super.init()
        // Delegate + categories are inert (no permission prompt) — safe at
        // launch; only requestAuthorization is deferred.
        center.delegate = self
        let category = UNNotificationCategory(
            identifier: Self.anomalyCategoryID,
            actions: [
                UNNotificationAction(identifier: Self.investigateActionID, title: "Investigate", options: [.foreground]),
                UNNotificationAction(identifier: Self.snoozeActionID, title: "Snooze 1 hour"),
                UNNotificationAction(identifier: Self.normalActionID, title: "Normal for me"),
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    /// A short, plain-English label for the anomaly kind — for the notification
    /// subtitle, so a non-technical reader sees "GPU running hot," not the raw
    /// rule name "gpu.saturation."
    private static func plainKind(_ kind: Anomaly.Kind) -> String { kind.plainLabel }

    func post(for judged: AppState.JudgedAnomaly, conditionKey: String) async {
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        if let marker = judged.returnedWorse {
            // The anti-mute re-alert says WHY it's back, up front.
            content.title = "\(judged.anomaly.identity.executableName): \(marker.lowercased())"
        } else {
            content.title = "\(judged.anomaly.identity.executableName) is anomalous"
        }
        // Subtitle: a short, plain-English "what" (not the raw rule name), so
        // the notification reads title → what → do rather than a dense wall.
        content.subtitle = Self.plainKind(judged.anomaly.kind)
        // Body: the one actionable line. The long identity paragraph
        // (whatItIs) belongs in the app card, not a glanceable notification —
        // it's what made this feel squished.
        content.body = judged.card.suggestedAction
        // Surfaced == confirmed high-confidence (Phase 2 gate in AppState) —
        // the ONLY level that may break Focus. Everything else in the app is
        // quieter than this by design.
        content.interruptionLevel = .timeSensitive
        content.sound = nil // silence is the brand — presence, not noise
        // Thread by process LINEAGE (bundle ID or executable name), not pid:
        // a restarting runaway coalesces instead of stacking.
        content.threadIdentifier = BaselineStore.key(for: judged.anomaly.identity)
        content.categoryIdentifier = Self.anomalyCategoryID
        content.userInfo = ["conditionKey": conditionKey]

        do {
            try await center.add(UNNotificationRequest(
                identifier: judged.id.uuidString,
                content: content,
                trigger: nil
            ))
        } catch {
            // Notification failure must never affect detection; the popover
            // still carries the card.
            print("[anomalous] notification failed: \(error.localizedDescription)")
        }
    }

    /// Journal-worthy resolution, `.passive`: no sound, never breaks Focus,
    /// posted only when the user opted in (Settings › General).
    func postResolution(processName: String, resolutionLabel: String) async {
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "\(processName): \(resolutionLabel.lowercased())"
        content.body = "Filed in the journal."
        content.interruptionLevel = .passive
        content.sound = nil
        content.threadIdentifier = processName

        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let conditionKey = response.notification.request.content.userInfo["conditionKey"] as? String
        await MainActor.run {
            switch action {
            case Self.snoozeActionID:
                if let conditionKey { onSnoozeCondition?(conditionKey) }
            case Self.normalActionID:
                if let conditionKey { onAcknowledgeCondition?(conditionKey) }
            case Self.investigateActionID, UNNotificationDefaultActionIdentifier:
                // Bring the menu-bar app forward; the popover itself has no
                // public open API — the lit status item is the affordance.
                NSApp.activate(ignoringOtherApps: true)
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A menu-bar (accessory) app is "foreground" whenever its popover is
        // open — still show the banner (the popover may be showing something else).
        [.banner, .list]
    }
}
