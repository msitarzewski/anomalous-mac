import Foundation

/// How a surfaced anomaly left the active list.
public enum AnomalyResolution: String, Codable, Sendable, CaseIterable {
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
public struct JournalEntry: Codable, Sendable, Identifiable, Equatable {
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

        init() {}

        enum CodingKeys: String, CodingKey { case schemaVersion, entries }

        // Lenient decode: a single corrupt entry must NOT nuke the whole
        // history. `journal.json` is user-writable and a crash can truncate it
        // mid-write, so decode entries element-by-element and drop only the bad
        // ones. (The all-or-nothing default would silently erase everything,
        // then persist the emptiness on the next save.)
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            let lossy = (try? c.decode([LossyEntry].self, forKey: .entries)) ?? []
            entries = lossy.compactMap(\.value)
        }
    }

    /// Decodes to a `JournalEntry` or, if that entry is malformed, to nil —
    /// consuming exactly one array slot either way so iteration never stalls.
    private struct LossyEntry: Decodable {
        let value: JournalEntry?
        init(from decoder: any Decoder) throws { value = try? JournalEntry(from: decoder) }
    }

    /// Refuse to load a `journal.json` far larger than any real history — a
    /// crash-corrupted or hostile local file shouldn't be able to OOM us at
    /// launch. 128 MB is ~400k entries; well beyond even an "Unlimited" journal.
    static let maxLoadableBytes = 128 * 1024 * 1024

    /// Default retention when the user hasn't chosen one. The cap is
    /// user-configurable (History window depth setting); this is the fallback.
    public static let defaultMaxEntries = 1000

    private let fileURL: URL
    private var snapshot = Snapshot()
    private var loaded = false
    /// How many incidents to retain. Configurable at runtime via `setMaxEntries`
    /// so the History window's depth control can raise or lower it live.
    private var maxEntries: Int

    public init(fileURL: URL, maxEntries: Int = AnomalyJournal.defaultMaxEntries) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
    }

    /// Change retention depth. Trims immediately if the new cap is smaller so
    /// the on-disk history matches the user's choice right away.
    public func setMaxEntries(_ newValue: Int) {
        maxEntries = max(1, newValue)
        if snapshot.entries.count > maxEntries {
            snapshot.entries.removeLast(snapshot.entries.count - maxEntries)
            save()
        }
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // Bound the read: skip an absurdly large (corrupt/hostile) file.
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxLoadableBytes {
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        snapshot = stored
        // Enforce the retention cap on load too — the file may have been written
        // by a build with a larger cap, or the user may have lowered it.
        if snapshot.entries.count > maxEntries {
            snapshot.entries = Array(snapshot.entries.prefix(maxEntries))
        }
    }

    public func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
            // Owner-only: the journal is private incident history. Same-user
            // processes can still read it, but nothing else should.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Record a resolution (newest first), bounded to `maxEntries`.
    public func record(_ entry: JournalEntry) {
        snapshot.entries.insert(entry, at: 0)
        if snapshot.entries.count > maxEntries {
            snapshot.entries.removeLast(snapshot.entries.count - maxEntries)
        }
        save()
    }

    /// Recent entries, newest first. With no limit, returns the full retained
    /// history (up to the configured cap) so the History window and dashboard
    /// honour the user's depth choice — 5k / 25k / Unlimited included, not just
    /// the first 1,000.
    public func recent(_ limit: Int? = nil) -> [JournalEntry] {
        Array(snapshot.entries.prefix(limit ?? maxEntries))
    }

    public func clear() {
        snapshot.entries.removeAll()
        save()
    }
}
