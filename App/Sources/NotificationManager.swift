import Foundation
import UserNotifications
import AnomalousCore

/// Diagnosis-card notifications, bound by memory-bank/design-guidelines.md:
/// interruption level is `.active` — NEVER Time Sensitive (routine sensor
/// findings) or Critical (entitlement-gated, safety/gov). One thread per
/// process so repeat findings coalesce instead of stacking. No custom
/// action buttons yet — destructive actions require the confirmation UI
/// (build-order step 3); a notification click opens the app, which is the
/// default behavior and needs no redundant "View" action.
@MainActor
final class NotificationManager {
    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    func post(for judged: AppState.JudgedAnomaly) async {
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "\(judged.anomaly.identity.executableName) is anomalous"
        content.subtitle = judged.anomaly.kind.rawValue.replacingOccurrences(of: "_", with: " ")
        content.body = "\(judged.card.whatItIs)\n\(judged.card.suggestedAction)"
        content.interruptionLevel = .active
        content.sound = nil // silence is the brand
        content.threadIdentifier = judged.anomaly.identity.executableName

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

    private func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert])
    }
}
