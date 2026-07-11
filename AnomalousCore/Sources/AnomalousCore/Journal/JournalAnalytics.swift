import Foundation

/// The time span the History dashboard summarises. `Unlimited` covers the whole
/// retained journal. The four cases are the shipped range picker.
public enum HistoryRange: String, CaseIterable, Sendable, Identifiable {
    case day, week, month, unlimited
    public var id: String { rawValue }

    /// Lookback window, or nil for "everything retained".
    public var window: TimeInterval? {
        switch self {
        case .day:       return 24 * 3600
        case .week:      return 7 * 24 * 3600
        case .month:     return 30 * 24 * 3600
        case .unlimited: return nil
        }
    }

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .unlimited: return "Unlimited"
        }
    }
}

/// One process's incident history within a range: every episode it had, plus
/// the rollups the UI shows (count, first/last seen, the kinds it tripped, and
/// how often it cleared without you lifting a finger).
public struct ProcessHistory: Equatable, Sendable, Identifiable {
    /// Stable identity — bundle id when the process has one, else its name.
    /// Matches `RecurrenceFinder`'s grouping so a daemon never merges with a
    /// same-named bundled app.
    public let id: String
    public let displayName: String
    public let bundleID: String?
    /// Episodes newest-first.
    public let episodes: [JournalEntry]
    public let count: Int
    public let firstDetectedAt: Date
    public let lastResolvedAt: Date
    /// Distinct anomaly kinds this process tripped, most frequent first.
    public let kinds: [String]
    /// Fraction that cleared with no user action (recovered or the process
    /// simply ended) — the "no action needed" signal.
    public let selfResolvedRate: Double
}

/// Everything the dashboard needs, derived from the journal in one pass.
public struct AnomalyDigest: Equatable, Sendable {
    public let range: HistoryRange
    public let total: Int
    public let distinctProcesses: Int
    /// Fraction of incidents that cleared with no user action.
    public let selfResolvedRate: Double
    /// Raw kind counts, most common first (the low-level breakdown; several raw
    /// kinds can share a display label — e.g. sustained_cpu + cputime_ratio).
    public let byKind: [KindCount]
    /// DISPLAY types, most common first: raw kinds folded by their plain label
    /// (sustained_cpu + cputime_ratio → one "High CPU" with the summed count).
    /// This is what the dashboard charts and the "most common" tile read — one
    /// bar per label, so counts always match the bars.
    public let byType: [TypeCount]
    /// Resolution counts in a stable order (the enum's order).
    public let byResolution: [ResolutionCount]
    /// Incidents per calendar day, ascending — sparse (only days with activity).
    public let perDay: [DayCount]
    /// Processes, most incidents first (ties broken by most-recent).
    public let processes: [ProcessHistory]

    /// The most common DISPLAY type (plain label), correctly aggregated.
    public var mostCommonType: TypeCount? { byType.first }

    public struct KindCount: Equatable, Sendable, Identifiable {
        public let kind: String
        public let count: Int
        public var id: String { kind }
    }
    public struct TypeCount: Equatable, Sendable, Identifiable {
        /// Plain, non-technical label ("High CPU").
        public let label: String
        /// Incidents across every raw kind sharing this label.
        public let count: Int
        /// A representative raw kind, for the chart colour (all kinds under one
        /// label share a colour, so any is fine; chosen deterministically).
        public let representativeKind: String
        public var id: String { label }
    }
    public struct ResolutionCount: Equatable, Sendable, Identifiable {
        public let resolution: AnomalyResolution
        public let count: Int
        public var id: String { resolution.rawValue }
    }
    public struct DayCount: Equatable, Sendable, Identifiable {
        public let day: Date
        public let count: Int
        public var id: TimeInterval { day.timeIntervalSince1970 }
    }
}

/// Pure aggregation over the local journal — inject `entries`, `now`, and a
/// calendar so it unit-tests without any app state (same discipline as
/// `RecurrenceFinder`). No I/O, no persistence.
public enum JournalAnalytics {
    /// A resolution counts as "self-resolved" when the user did nothing: the
    /// process calmed down on its own (`recovered`) or exited (`ended`).
    static let selfResolvedKinds: Set<AnomalyResolution> = [.recovered, .ended]

    public static func digest(
        from entries: [JournalEntry],
        range: HistoryRange,
        now: Date,
        calendar: Calendar = .current
    ) -> AnomalyDigest {
        let scoped: [JournalEntry]
        if let window = range.window {
            let cutoff = now.addingTimeInterval(-window)
            scoped = entries.filter { $0.resolvedAt >= cutoff }
        } else {
            scoped = entries
        }

        let total = scoped.count
        let selfResolved = scoped.lazy.filter { selfResolvedKinds.contains($0.resolution) }.count
        let selfRate = total == 0 ? 0 : Double(selfResolved) / Double(total)

        // ---- by kind (raw; most common first; ties alphabetical for stability) ----
        let byKind = tally(scoped.map(\.kind))
            .map { AnomalyDigest.KindCount(kind: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind < $1.kind }

        // ---- by display type: fold raw kinds by their plain label so kinds
        // that share a name (sustained_cpu + cputime_ratio → "High CPU") are one
        // bar with the summed count. The representative raw kind (min, for
        // determinism) drives the colour — kinds under one label share a colour.
        let byType = Dictionary(grouping: scoped) { displayLabel(forKind: $0.kind) }
            .map { label, items in
                AnomalyDigest.TypeCount(
                    label: label,
                    count: items.count,
                    representativeKind: items.map(\.kind).min() ?? label
                )
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }

        // ---- by resolution (stable enum order) ----
        let resCounts = Dictionary(grouping: scoped, by: \.resolution).mapValues(\.count)
        let byResolution = AnomalyResolution.allCases.compactMap { res -> AnomalyDigest.ResolutionCount? in
            guard let n = resCounts[res], n > 0 else { return nil }
            return AnomalyDigest.ResolutionCount(resolution: res, count: n)
        }

        // ---- per day (sparse, ascending) ----
        let byDay = Dictionary(grouping: scoped) { calendar.startOfDay(for: $0.resolvedAt) }
        let perDay = byDay.map { AnomalyDigest.DayCount(day: $0.key, count: $0.value.count) }
            .sorted { $0.day < $1.day }

        // ---- per process ----
        let grouped = Dictionary(grouping: scoped) { identityKey(bundleID: $0.bundleID, name: $0.processName) }
        let processes = grouped.map { (key, group) -> ProcessHistory in
            let sorted = group.sorted { $0.resolvedAt > $1.resolvedAt }   // newest first
            let selfN = group.filter { selfResolvedKinds.contains($0.resolution) }.count
            return ProcessHistory(
                id: key,
                displayName: sorted.first?.processName ?? key,
                bundleID: sorted.first?.bundleID,
                episodes: sorted,
                count: group.count,
                firstDetectedAt: group.map(\.detectedAt).min() ?? sorted.first!.detectedAt,
                lastResolvedAt: group.map(\.resolvedAt).max() ?? sorted.first!.resolvedAt,
                kinds: tally(group.map(\.kind))
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map(\.key),
                selfResolvedRate: group.isEmpty ? 0 : Double(selfN) / Double(group.count)
            )
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastResolvedAt > $1.lastResolvedAt }

        return AnomalyDigest(
            range: range,
            total: total,
            distinctProcesses: processes.count,
            selfResolvedRate: selfRate,
            byKind: byKind,
            byType: byType,
            byResolution: byResolution,
            perDay: perDay,
            processes: processes
        )
    }

    /// Plain display label for a raw kind rawValue — the same wording as the
    /// cards and notifications (`Anomaly.Kind.plainLabel`), falling back to a
    /// de-underscored raw value for anything unrecognised.
    static func displayLabel(forKind kind: String) -> String {
        Anomaly.Kind(rawValue: kind)?.plainLabel ?? kind.replacingOccurrences(of: "_", with: " ")
    }

    /// Grouping identity — bundle id when present, else the process name.
    /// Mirrors `RecurrenceFinder` so the same process reads consistently in both.
    static func identityKey(bundleID: String?, name: String) -> String {
        if let bundleID, !bundleID.isEmpty { return "bundle:" + bundleID }
        return "name:" + name
    }

    private static func tally(_ values: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts
    }
}
