import Foundation

/// How a surfaced anomaly left the active list.
public enum AnomalyResolution: String, Codable, Sendable {
    case recovered     // the process returned to normal on its own
    case ended         // the process exited
    case dismissed     // the user dismissed the card
    case actioned      // the user took the offered action (quit / stop / restart)
    case acknowledged  // "normal for me" — the envelope was raised (Phase 4)
    case snoozed       // time-boxed snooze; re-surfaces on expiry if still active

    public var label: String {
        switch self {
        case .recovered: return "Recovered"
        case .ended: return "Process ended"
        case .dismissed: return "Dismissed"
        case .actioned: return "Handled"
        case .acknowledged: return "Marked normal"
        case .snoozed: return "Snoozed"
        }
    }

    // Codable back-compat, both directions: an old journal file always
    // decodes (its values are a subset), and a journal written by a NEWER
    // build with cases this build doesn't know must not nuke the whole
    // history — unknown raw values degrade to `.dismissed` instead of
    // throwing (the AnomalyJournal snapshot decode is all-or-nothing).
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AnomalyResolution(rawValue: raw) ?? .dismissed
    }
}

/// Summary of a process+kind that genuinely resolved before and has now
/// re-tripped. Drives the "First flagged … · returned N×" card footer so a
/// flapping process reads as an ongoing saga rather than a fresh blip.
public struct RecurrenceSummary: Equatable, Sendable {
    /// The earliest detection across the recent episodes (this one + priors) —
    /// the true start of the saga, not just this instance.
    public let firstFlaggedAt: Date
    /// How many prior resolved episodes there were (always >= 1).
    public let returnCount: Int
    /// Whether the saga began within the same calendar day as `now` — lets the
    /// UI say "returned N× today" only when it's actually accurate.
    public let scopedToToday: Bool

    public init(firstFlaggedAt: Date, returnCount: Int, scopedToToday: Bool) {
        self.firstFlaggedAt = firstFlaggedAt
        self.returnCount = returnCount
        self.scopedToToday = scopedToToday
    }
}

/// Reads recurrence out of the local journal. Pure and deterministic (inject
/// `now`/`calendar`) so it can be unit-tested without app state.
public enum RecurrenceFinder {
    /// Resolutions that mean the condition *genuinely went away* — so a fresh
    /// detection afterward is a true recurrence. Excludes `.dismissed` (a
    /// view-clear; the condition may have persisted) and `.acknowledged` /
    /// `.snoozed` (the anti-mute re-alert marker owns those).
    static let genuinelyResolved: Set<AnomalyResolution> = [.recovered, .ended, .actioned]

    /// Prior genuinely-resolved episodes of the same identity + kind within
    /// `window` before `now`. Identity matches on bundle id when the live
    /// anomaly has one, else on process name (and only against other
    /// bundle-less entries, so an app's helper never cross-matches the app).
    /// Returns nil for a genuine first flag.
    public static func summary(
        kind: String,
        bundleID: String?,
        processName: String,
        detectedAt: Date,
        in entries: [JournalEntry],
        now: Date,
        window: TimeInterval = 24 * 3600,
        calendar: Calendar = .current
    ) -> RecurrenceSummary? {
        let cutoff = now.addingTimeInterval(-window)
        let priors = entries.filter { e in
            guard e.kind == kind,
                  genuinelyResolved.contains(e.resolution),
                  e.resolvedAt >= cutoff
            else { return false }
            if let bundleID { return e.bundleID == bundleID }
            return e.bundleID == nil && e.processName == processName
        }
        guard !priors.isEmpty else { return nil }
        let firstFlagged = min(detectedAt, priors.map(\.detectedAt).min() ?? detectedAt)
        return RecurrenceSummary(
            firstFlaggedAt: firstFlagged,
            returnCount: priors.count,
            scopedToToday: calendar.isDate(firstFlagged, inSameDayAs: now)
        )
    }
}

/// A resolved anomaly, kept as reviewable history. The active list shows only
/// live problems; when one clears — it recovers, the process exits, or the user
/// handles it — it moves here so nothing silently vanishes.
public struct JournalEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let processName: String
    public let bundleID: String?
    public let kind: String        // Anomaly.Kind rawValue
    public let summary: String     // card.whatItIs
    public let action: String      // card.suggestedAction
    public let safetyTier: Int
    public let judgedByModel: Bool
    public let detectedAt: Date
    public let resolvedAt: Date
    public let resolution: AnomalyResolution

    public init(
        id: UUID = UUID(),
        processName: String,
        bundleID: String?,
        kind: String,
        summary: String,
        action: String,
        safetyTier: Int,
        judgedByModel: Bool,
        detectedAt: Date,
        resolvedAt: Date = .now,
        resolution: AnomalyResolution
    ) {
        self.id = id
        self.processName = processName
        self.bundleID = bundleID
        self.kind = kind
        self.summary = summary
        self.action = action
        self.safetyTier = safetyTier
        self.judgedByModel = judgedByModel
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    /// How long the anomaly was active before it resolved.
    public var duration: TimeInterval { max(0, resolvedAt.timeIntervalSince(detectedAt)) }
}

/// Persists the anomaly journal across launches. **Local only, always** —
/// the journal is the user's private incident history; only anonymous
/// signatures ever leave the machine (memory-bank privacy posture).
public actor AnomalyJournal {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var entries: [JournalEntry] = []
    }

    /// Keep the journal bounded to the most recent incidents.
    public static let maxEntries = 500

    private let fileURL: URL
    private var snapshot = Snapshot()
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        snapshot = stored
    }

    public func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Record a resolution (newest first), bounded to `maxEntries`.
    public func record(_ entry: JournalEntry) {
        snapshot.entries.insert(entry, at: 0)
        if snapshot.entries.count > Self.maxEntries {
            snapshot.entries.removeLast(snapshot.entries.count - Self.maxEntries)
        }
        save()
    }

    public func recent(_ limit: Int = 200) -> [JournalEntry] {
        Array(snapshot.entries.prefix(limit))
    }

    public func clear() {
        snapshot.entries.removeAll()
        save()
    }
}
