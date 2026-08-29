import Foundation

/// The byte-for-byte send log — the client half of the two-ledger trust
/// mechanism (seed.md: "auditable beats approvable"). EVERY transmission
/// (signature or triage payload) is recorded exactly as sent, viewable in
/// the history UI, diffable against the server-side mirror.
public actor SendLog {
    public struct Entry: Sendable, Codable, Identifiable {
        public enum Flow: String, Sendable, Codable {
            /// Anonymous signature — never account-linked.
            case signature
            /// Account-linked triage payload.
            case triage
            /// Anonymous discovery lookup — the process name (never paths or
            /// args) sent to research an unknown process. Never account-linked.
            case discovery
        }
        public let id: UUID
        public let flow: Flow
        public let sentAt: Date
        /// The exact bytes that went on the wire.
        public let payload: Data
    }

    private let directory: URL
    private var entries: [Entry] = []
    public static let maxEntries = 100
    public static let retentionSeconds: TimeInterval = 7 * 24 * 3600

    public init(directory: URL) {
        self.directory = directory
        Self.pruneDirectory(directory)
    }

    public func record(flow: Entry.Flow, payload: Data) throws -> Entry {
        let entry = Entry(id: UUID(), flow: flow, sentAt: Date(), payload: payload)
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        try persist(entry)
        Self.pruneDirectory(directory)
        return entry
    }

    public func all() -> [Entry] { entries }

    private func persist(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(entry.sentAt.timeIntervalSince1970)-\(entry.id.uuidString).json")
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    /// Prune disk files exceeding max retention or capacity
    public nonisolated static func pruneDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            return
        }
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let cutoff = Date().addingTimeInterval(-Self.retentionSeconds)

        var validFiles: [(url: URL, date: Date)] = []
        for file in jsonFiles {
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if modDate < cutoff {
                try? fm.removeItem(at: file)
            } else {
                validFiles.append((url: file, date: modDate))
            }
        }

        // Enforce max disk entries cap
        if validFiles.count > Self.maxEntries {
            validFiles.sort { $0.date < $1.date }
            let excess = validFiles.count - Self.maxEntries
            for item in validFiles.prefix(excess) {
                try? fm.removeItem(at: item.url)
            }
        }
    }
}
