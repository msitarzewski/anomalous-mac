import WidgetKit
import SwiftUI
import AppIntents
import AnomalousCore

// The ambient status widget — silence, made visible (phase-4). At rest it is
// deliberately IGNORABLE: the dimmed Anomalous mark and "All systems nominal.", no
// gauges, no ticking numbers (the incumbents' anxiety theater). It comes to
// life only when a confirmed (high-confidence, surfaced) anomaly exists, and
// then it offers the same acknowledgment verbs as the card, inline.
//
// State-driven, not polling: the app writes SensorStatus to the App Group at
// each tick and reloads timelines; the provider just reads the file.

@main
struct AnomalousWidgetBundle: WidgetBundle {
    var body: some Widget {
        AnomalousStatusWidget()
        MonitoringControl()
        RunScanControl()
    }
}

// MARK: - Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: SensorStatus
}

struct StatusProvider: TimelineProvider {
    private func current() -> StatusEntry {
        let status = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SensorStatus.appGroupID)
            .flatMap { SensorStatus.read(from: SensorStatus.fileURL(in: $0)) }
        return StatusEntry(date: .now, status: status ?? SensorStatus())
    }

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, status: SensorStatus(watchedProcessCount: 500))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // One entry; the app pushes reloads on state changes. `.never` keeps
        // the widget free while quiet — exactly the brand.
        completion(Timeline(entries: [current()], policy: .never))
    }
}

// MARK: - Widget

struct AnomalousStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bot.anomalous.sensor.widget.status", provider: StatusProvider()) { entry in
            StatusWidgetView(status: entry.status)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Anomalous")
        .description("Quiet while all is nominal. Comes to life only when something needs you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusWidgetView: View {
    let status: SensorStatus
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let top = status.topCard, status.activeCount > 0 {
            anomaly(top)
        } else {
            nominal
        }
    }

    /// At rest: the mark, dimmed, and one calm line — matching the menu-bar
    /// popover's "All systems nominal." Ignorable on purpose.
    private var nominal: some View {
        VStack(spacing: 8) {
            Image("StatusMark")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(.tertiary)
            Text(status.monitoringEnabled ? "All systems nominal." : "Monitoring paused")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(status.monitoringEnabled
            ? "Anomalous: nothing is wrong"
            : "Anomalous: monitoring is paused")
    }

    /// Alive: process, plain one-liner, tier as icon + word (never color
    /// alone), and the acknowledgment verbs inline (medium family).
    private func anomaly(_ top: SensorStatus.TopCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(top.processName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                tierBadge(top.safetyTier)
            }
            if top.returnedWorse {
                Label("Returned, worse", systemImage: "arrow.uturn.up.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text(top.summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemSmall ? 3 : 2)
            if status.activeCount > 1 {
                Text("+ \(status.activeCount - 1) more in the menu bar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if family != .systemSmall {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(intent: SnoozeAnomalyIntent(conditionKey: top.conditionKey, processName: top.processName)) {
                        Label("Snooze 1h", systemImage: "moon.zzz")
                            .font(.body)
                    }
                    Button(intent: AcknowledgeAnomalyIntent(conditionKey: top.conditionKey, processName: top.processName)) {
                        Label("Normal for me", systemImage: "checkmark.seal")
                            .font(.body)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Icon + word, mirroring the card's status pill (WCAG: never color alone).
    private func tierBadge(_ tier: Int) -> some View {
        let (symbol, word, tint): (String, String, Color) = switch tier {
        case 1: ("checkmark.circle.fill", "Safe", .green)
        case 2: ("exclamationmark.triangle.fill", "Caution", .orange)
        default: ("info.circle.fill", "Info", .secondary)
        }
        return HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small).foregroundStyle(tint)
            Text(word).font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(word)")
    }
}

// MARK: - Control Center controls (ControlWidget IS on macOS 26+/27 SDK)

struct MonitoringControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "bot.anomalous.sensor.widget.monitoring",
            provider: MonitoringValueProvider()
        ) { isOn in
            ControlWidgetToggle("Monitoring", isOn: isOn, action: ToggleMonitoringIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "waveform" : "waveform.slash")
            }
        }
        .displayName("Anomalous Monitoring")
        .description("Turn anomaly monitoring on or off.")
    }
}

struct MonitoringValueProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        UserDefaults(suiteName: SensorStatus.appGroupID)?
            .object(forKey: "monitoringEnabled") as? Bool ?? true
    }
}

struct RunScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "bot.anomalous.sensor.widget.runscan") {
            ControlWidgetButton(action: RunScanIntent()) {
                Label("Run Scan", systemImage: "waveform.badge.magnifyingglass")
            }
        }
        .displayName("Anomalous Scan")
        .description("Run an immediate scan of all processes.")
    }
}
