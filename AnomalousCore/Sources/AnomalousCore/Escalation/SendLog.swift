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

    public init(directory: URL) {
        self.directory = directory
    }

    public func record(flow: Entry.Flow, payload: Data) throws -> Entry {
        let entry = Entry(id: UUID(), flow: flow, sentAt: Date(), payload: payload)
        entries.append(entry)
        try persist(entry)
        return entry
    }

    public func all() -> [Entry] { entries }

    private func persist(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(entry.sentAt.timeIntervalSince1970)-\(entry.id.uuidString).json")
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }
}
