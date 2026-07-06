import Foundation
import AppIntents
import AnomalousCore

// App Intents — the ONE front door to Siri / Spotlight / Shortcuts / Control
// Center / Widgets (phase-4 + research/platform-macos27.md §1). This file is
// compiled into BOTH the app and the widget extension:
//   • In the app process, `IntentBridge` is wired to AppState and intents act
//     on live state directly.
//   • In the widget/Control Center process the bridge is nil, so intents read
//     the App Group status JSON and enqueue WidgetCommands the app drains
//     (nudged by a name-only distributed notification; the 90s tick is the
//     backstop). This file therefore must NOT reference AppState directly.

// MARK: - Bridge

/// Process-local wiring: the app assigns these at AppState init; the widget
/// process leaves them nil and falls back to the App Group.
@MainActor
enum IntentBridge {
    static var statusProvider: (() -> SensorStatus)?
    static var runScan: (() async -> Void)?
    static var snoozeAll: ((TimeInterval) -> Void)?
    static var acknowledgeCondition: ((String) async -> Void)?
    static var snoozeCondition: ((String, TimeInterval) async -> Void)?
    static var setMonitoring: ((Bool) -> Void)?
    static var anomalyEntities: (() -> [AnomalyEventEntity])?
}

/// Group-container fallbacks shared by the intents.
enum IntentPlumbing {
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SensorStatus.appGroupID)
    }

    static func readStatus() -> SensorStatus {
        guard let container = containerURL,
              let status = SensorStatus.read(from: SensorStatus.fileURL(in: container))
        else { return SensorStatus(monitoringEnabled: true, activeCount: 0, quietCount: 0, watchedProcessCount: 0) }
        return status
    }

    /// Queue a command for the app + nudge it (name-only: a sandboxed appex
    /// may not attach userInfo to a distributed notification).
    static func enqueue(_ command: WidgetCommand) {
        guard let container = containerURL else { return }
        // Sign with the shared Keychain key so the app can tell this real,
        // widget-originated command from one a malicious same-user process
        // drops into the container. If the key isn't readable we still enqueue
        // (unsigned) — the app will reject it, which is the safe outcome.
        let outgoing = SharedSecret.key(createIfMissing: false).map { command.signed(with: $0) } ?? command
        WidgetCommand.enqueue(outgoing, at: WidgetCommand.fileURL(in: container))
        DistributedNotificationCenter.default()
            .postNotificationName(Notification.Name(SensorStatus.commandNotification), object: nil, deliverImmediately: true)
    }

    @MainActor
    static func currentStatus() -> SensorStatus {
        IntentBridge.statusProvider?() ?? readStatus()
    }
}

// MARK: - Entities

/// A live anomaly, exposed for Siri/Spotlight/Shortcuts with attribution.
struct AnomalyEventEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Anomaly"
    static let defaultQuery = AnomalyEventQuery()

    /// The condition key (`process lineage · kind · dimension`) — stable for
    /// the anomaly's lifetime and directly actionable by the snooze/ack intents.
    var id: String
    var processName: String
    var kind: String
    var summary: String
    var safetyTier: Int
    var detectedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(processName)",
            subtitle: "\(kind) — \(summary)"
        )
    }
}

struct AnomalyEventQuery: EntityQuery {
    @MainActor
    private func all() -> [AnomalyEventEntity] {
        if let live = IntentBridge.anomalyEntities?() { return live }
        // Widget process: only the top card is in the status snapshot.
        guard let top = IntentPlumbing.readStatus().topCard else { return [] }
        return [AnomalyEventEntity(
            id: top.conditionKey, processName: top.processName, kind: top.kind,
            summary: top.summary, safetyTier: top.safetyTier, detectedAt: .now
        )]
    }

    func entities(for identifiers: [String]) async throws -> [AnomalyEventEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AnomalyEventEntity] {
        await all()
    }
}

/// The diagnosis for an anomaly — what it is and what to do about it.
struct DiagnosisEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Diagnosis"
    static let defaultQuery = DiagnosisQuery()

    var id: String            // same condition key as the anomaly it explains
    var whatItIs: String
    var suggestedAction: String
    var safetyTier: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(whatItIs)", subtitle: "\(suggestedAction)")
    }
}

struct DiagnosisQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DiagnosisEntity] {
        try await AnomalyEventQuery().entities(for: identifiers).map {
            DiagnosisEntity(id: $0.id, whatItIs: $0.summary, suggestedAction: "Open Anomalous for the guided action.", safetyTier: $0.safetyTier)
        }
    }

    func suggestedEntities() async throws -> [DiagnosisEntity] {
        try await entities(for: AnomalyEventQuery().suggestedEntities().map(\.id))
    }
}

// MARK: - Intents

/// "Is my Mac behaving normally?" — the one-sentence honest answer.
struct ShowStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Status"
    static let description = IntentDescription(
        "Is this Mac behaving normally? Summarizes active anomalies and quiet findings.",
        categoryName: "Monitoring"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let status = IntentPlumbing.currentStatus()
        return .result(value: status.summaryLine, dialog: IntentDialog(stringLiteral: status.summaryLine))
    }
}

/// Trigger one sensor tick right now.
struct RunScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Scan"
    static let description = IntentDescription(
        "Runs an immediate scan of all processes.",
        categoryName: "Monitoring"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let runScan = IntentBridge.runScan {
            await runScan()
            let status = IntentPlumbing.currentStatus()
            return .result(dialog: IntentDialog(stringLiteral: "Scan complete. \(status.summaryLine)"))
        }
        IntentPlumbing.enqueue(WidgetCommand(action: .runScan))
        return .result(dialog: "Scan requested.")
    }
}

enum SnoozeDuration: String, AppEnum {
    case oneHour
    case restOfDay

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Duration"
    static let caseDisplayRepresentations: [SnoozeDuration: DisplayRepresentation] = [
        .oneHour: "1 hour",
        .restOfDay: "Rest of today",
    ]

    var seconds: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .restOfDay:
            let endOfDay = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
            return max(60, endOfDay.timeIntervalSinceNow)
        }
    }
}

/// Global alert snooze — detection keeps running; notifications go quiet.
struct SnoozeAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Alerts"
    static let description = IntentDescription(
        "Silences anomaly notifications for a while. Detection keeps running.",
        categoryName: "Monitoring"
    )

    @Parameter(title: "Duration", default: .oneHour)
    var duration: SnoozeDuration

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let snoozeAll = IntentBridge.snoozeAll {
            snoozeAll(duration.seconds)
        } else {
            IntentPlumbing.enqueue(WidgetCommand(action: .snoozeAll, snoozeSeconds: duration.seconds))
        }
        let label = duration == .oneHour ? "for an hour" : "for the rest of today"
        return .result(dialog: IntentDialog(stringLiteral: "Alerts snoozed \(label). Detection keeps running."))
    }
}

/// "Normal for me" on one condition — the widget tile's button.
struct AcknowledgeAnomalyIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Normal for Me"
    static let description = IntentDescription(
        "Accepts an anomaly's current behavior as normal. You are re-alerted if it gets materially worse, changes behavior, or the process restarts.",
        categoryName: "Monitoring"
    )

    @Parameter(title: "Anomaly")
    var target: AnomalyEventEntity

    init() {}
    init(conditionKey: String, processName: String) {
        self.target = AnomalyEventEntity(
            id: conditionKey, processName: processName, kind: "", summary: "",
            safetyTier: 3, detectedAt: .now
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let acknowledge = IntentBridge.acknowledgeCondition {
            await acknowledge(target.id)
        } else {
            IntentPlumbing.enqueue(WidgetCommand(action: .acknowledge, conditionKey: target.id))
        }
        return .result(dialog: IntentDialog(stringLiteral: "Marked normal for you. It never mutes — you'll hear about it again only if it gets worse."))
    }
}

/// Time-boxed snooze on one condition — the widget tile's other button.
struct SnoozeAnomalyIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Anomaly"
    static let description = IntentDescription(
        "Snoozes one anomaly. It re-surfaces when the snooze expires if still active, or sooner if it gets materially worse.",
        categoryName: "Monitoring"
    )

    @Parameter(title: "Anomaly")
    var target: AnomalyEventEntity

    @Parameter(title: "Duration", default: .oneHour)
    var duration: SnoozeDuration

    init() {}
    init(conditionKey: String, processName: String, duration: SnoozeDuration = .oneHour) {
        self.target = AnomalyEventEntity(
            id: conditionKey, processName: processName, kind: "", summary: "",
            safetyTier: 3, detectedAt: .now
        )
        self.duration = duration
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let snooze = IntentBridge.snoozeCondition {
            await snooze(target.id, duration.seconds)
        } else {
            IntentPlumbing.enqueue(WidgetCommand(action: .snoozeCondition, conditionKey: target.id, snoozeSeconds: duration.seconds))
        }
        return .result(dialog: "Snoozed.")
    }
}

/// Monitoring on/off — the Control Center toggle's SetValueIntent.
struct ToggleMonitoringIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Monitoring"
    static let description = IntentDescription(
        "Turns Anomalous monitoring on or off.",
        categoryName: "Monitoring"
    )

    @Parameter(title: "Monitoring")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        if let setMonitoring = IntentBridge.setMonitoring {
            setMonitoring(value)
        } else {
            // Write the group default directly so the control reflects the
            // change instantly, then let the app reconcile.
            UserDefaults(suiteName: SensorStatus.appGroupID)?.set(value, forKey: "monitoringEnabled")
            IntentPlumbing.enqueue(WidgetCommand(action: .setMonitoring, monitoringEnabled: value))
        }
        return .result()
    }
}
