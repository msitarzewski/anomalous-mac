import Foundation

/// How a surfaced anomaly left the active list.
public enum AnomalyResolution: String, Codable, Sendable {
    case recovered  // the process returned to normal on its own
    case ended      // the process exited
    case dismissed  // the user dismissed the card
    case actioned   // the user took the offered action (quit / stop / restart)

    public var label: String {
        switch self {
        case .recovered: return "Recovered"
        case .ended: return "Process ended"
        case .dismissed: return "Dismissed"
        case .actioned: return "Handled"
        }
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
