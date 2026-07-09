import Foundation

/// One curated entry: identity + safety metadata for a daemon or app.
/// The LLM composes; the map is the source of truth. Safety tiers:
/// 1 = one-click safe (launchd respawns / user-owned), 2 = warn,
/// 3 = explain only, no button. Conservative by default — a confident
/// wrong kill button is worse than no button.
public struct KnowledgeEntry: Sendable, Codable, Identifiable {
    public var id: String { processName }
    public let processName: String
    public let displayName: String
    public let whatItIs: String
    public let ownedBy: String
    public let whenHotImplies: String
    public let safetyTier: Int
    public let safeAction: String?
    public let worstCase: String?
    /// Known causal links, e.g. dasd ↔ appstoreagent (hardcoded pairs at
    /// first; a real dependency graph is a later research problem).
    public let causallyLinked: [String]
}

/// Loads the curated map shipped in the bundle. Live extension arrives via
/// the known-issues feed (whole-feed pull, matched locally).
public struct KnowledgeMap: Sendable {
    private let entries: [String: KnowledgeEntry]

    public init(entries: [KnowledgeEntry]) {
        // First entry wins on duplicates — a curation slip must degrade,
        // never trap (a trap here crashes the app at launch).
        self.entries = Dictionary(entries.map { ($0.processName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func shipped() throws -> KnowledgeMap {
        guard let url = Bundle.module.url(forResource: "knowledge-map", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let entries = try JSONDecoder().decode([KnowledgeEntry].self, from: Data(contentsOf: url))
        return KnowledgeMap(entries: entries)
    }

    public func entry(forProcessName name: String) -> KnowledgeEntry? {
        entries[name]
    }

    /// Resolve a process to its corpus entry, tolerating channel-variant naming.
    /// An exact executable-name hit always wins; on a miss, a channel-suffixed
    /// bundle id (`dev.zed.Zed-Preview`) falls back to its canonical leaf
    /// ("Zed"), matched case-insensitively — so the Preview channel REUSES the
    /// base app's `zed` record instead of dropping to a bundle-id guess. Both
    /// the app's `hasCorpusEntry` gate and the engine's grounding go through
    /// here, so they never disagree about whether a process is known.
    public func entry(for identity: ProcessIdentity) -> KnowledgeEntry? {
        if let exact = entries[identity.executableName] { return exact }
        // Fallback ONLY for a recognized channel variant (dev.zed.Zed-Preview):
        // reuse the base app's record via the canonical bundle leaf, matched
        // case-insensitively. Gated on the channel so an ordinary app's bundle
        // leaf can never be loosely matched into a wrong (and possibly
        // "safe-to-kill") identity.
        guard identity.releaseChannel != nil, let leaf = identity.canonicalBundleLeaf else { return nil }
        return entries.values.first { $0.processName.caseInsensitiveCompare(leaf) == .orderedSame }
    }

    public var count: Int { entries.count }

    /// All entries (stable order by process name) — the corpus-merge and
    /// context-composition surface.
    public var allEntries: [KnowledgeEntry] {
        entries.values.sorted { $0.processName < $1.processName }
    }

    /// Merge pulled, VERIFIED corpus entries over the shipped map. A pulled
    /// entry WINS on the same process name — it went through the server-side
    /// review gate and is newer than the app bundle. `safeAction == nil` on
    /// a pulled entry is SEMANTIC ("no safe intervention exists"), so it
    /// legitimately replaces a shipped action rather than falling back to it.
    public func merging(pulled: [KnowledgeEntry]) -> KnowledgeMap {
        var merged = entries
        for entry in pulled {
            merged[entry.processName] = entry
        }
        return KnowledgeMap(entries: Array(merged.values))
    }
}
