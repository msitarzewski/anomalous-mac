import Foundation
import CryptoKit
import Security

// Phase 4: the acknowledgment envelope — "normal for me" that RAISES the
// per-condition envelope instead of muting it, plus the shared status/command
// currency the app and the widget extension trade through the App Group.
//
// Reuse analysis: BaselineStore (the closest analog) owns baselines, flags,
// and the diagnosis cache — the judgment core's memory. Acknowledgment is a
// USER-control store with different keys (condition, not lineage), a
// different lifecycle (spent on re-alert), and a different owner (Phase 4);
// the phase spec mandates a parallel actor. SensorStatus/WidgetCommand live
// here because they are the acknowledgment surface's wire shape (the widget's
// Snooze/"Normal for me" buttons round-trip through them) and both processes
// link AnomalousCore.

// MARK: - Acknowledgment record + pure re-alert decision

/// One acknowledged condition (`process lineage · kind · dimension`):
/// "this much, this way, is fine" — never "this process is fine forever."
public struct AcknowledgmentRecord: Codable, Sendable, Equatable {
    /// Magnitude (rule units: % CPU, MB, wakeups/s…) at acknowledgment time.
    public var acknowledgedMagnitude: Double
    /// Re-alert margin: re-alert fires when magnitude exceeds
    /// `acknowledgedMagnitude × envelopeMultiplier`. Defaults come from the
    /// intent heuristic (foreground user app 2.0, background/root 1.5).
    public var envelopeMultiplier: Double
    public var ackedAt: Date
    /// Set for time-boxed snoozes; nil for the durable "normal for me".
    public var snoozeUntil: Date?
    /// The process instance acknowledged. A different startAbsTime is a new
    /// instance → fresh evaluation (the anti-mute guarantee's third leg).
    public var processStartAbsTime: UInt64

    public init(
        acknowledgedMagnitude: Double,
        envelopeMultiplier: Double,
        ackedAt: Date = .now,
        snoozeUntil: Date? = nil,
        processStartAbsTime: UInt64
    ) {
        self.acknowledgedMagnitude = acknowledgedMagnitude
        self.envelopeMultiplier = envelopeMultiplier
        self.ackedAt = ackedAt
        self.snoozeUntil = snoozeUntil
        self.processStartAbsTime = processStartAbsTime
    }

    enum CodingKeys: String, CodingKey {
        case acknowledgedMagnitude, envelopeMultiplier, ackedAt, snoozeUntil, processStartAbsTime
    }

    // Resilient decoding (mirrors ProcessIdentity's rule): future additive
    // fields must degrade, not fail the whole acknowledgments.json.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acknowledgedMagnitude = try c.decodeIfPresent(Double.self, forKey: .acknowledgedMagnitude) ?? 0
        envelopeMultiplier = try c.decodeIfPresent(Double.self, forKey: .envelopeMultiplier)
            ?? AcknowledgmentDefaults.realertMargin
        ackedAt = try c.decodeIfPresent(Date.self, forKey: .ackedAt) ?? .distantPast
        snoozeUntil = try c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        processStartAbsTime = try c.decodeIfPresent(UInt64.self, forKey: .processStartAbsTime) ?? 0
    }
}

/// What an active condition should do given its acknowledgment state.
public enum ReAlertDecision: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case materiallyWorse = "materially_worse"
        case newInstance = "new_instance"
        case snoozeExpired = "snooze_expired"
    }

    /// No acknowledgment on file for this condition (includes a NEW
    /// kind/dimension on an otherwise-acked process — different key).
    case notAcknowledged
    /// Within the acknowledged envelope (or actively snoozed): stays off the
    /// UI, retained as a quiet finding for transparency.
    case suppress
    /// The anti-mute guarantee fired: surface it, say why.
    case realert(Reason)
}

/// Intent-heuristic defaults: a user-launched foreground app melting the GPU
/// is categorically different from a root background daemon doing it silently.
public enum AcknowledgmentDefaults {
    /// The tunable re-alert margin from the phase spec (`× 1.5`). Used as the
    /// floor/background default; the heuristic widens it for user apps.
    public static let realertMargin = 1.5
    public static let foregroundEnvelopeMultiplier = 2.0
    public static let backgroundEnvelopeMultiplier = 1.5

    /// "Foreground user app": bundled, user-installed (not Apple-system),
    /// not running as root. Intentional workloads mostly never nag.
    public static func isUserForegroundApp(
        bundleID: String?, installSource: InstallSource, ownerIsRoot: Bool
    ) -> Bool {
        bundleID != nil && installSource != .appleSystem && !ownerIsRoot
    }

    public static func envelopeMultiplier(
        bundleID: String?, installSource: InstallSource, ownerIsRoot: Bool
    ) -> Double {
        isUserForegroundApp(bundleID: bundleID, installSource: installSource, ownerIsRoot: ownerIsRoot)
            ? foregroundEnvelopeMultiplier
            : backgroundEnvelopeMultiplier
    }

    /// First-touch copy for the "Normal for me" confirm: soft for an
    /// intentional-looking user app, firm for a background/root process.
    public static func ackPrompt(processName: String, isUserForegroundApp: Bool) -> String {
        if isUserForegroundApp {
            return "\(processName) is working hard — expected? “Normal for me” accepts this much as its normal. You'll still be told if it gets materially worse, changes behavior, or restarts."
        }
        return "\(processName) is a background or system process behaving unusually. “Normal for me” raises its threshold slightly — it never mutes it. Any material worsening re-alerts."
    }
}

// MARK: - Store

/// Persists acknowledgments across launches — local-only, private, parallel
/// to BaselineStore's pattern (`Anomalous/acknowledgments.json`). The
/// decision logic is pure/static; the actor only owns persistence and the
/// consume-on-realert lifecycle.
public actor AcknowledgmentStore {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var records: [String: AcknowledgmentRecord] = [:]

        init() {}

        enum CodingKeys: String, CodingKey { case schemaVersion, records }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            records = try c.decodeIfPresent([String: AcknowledgmentRecord].self, forKey: .records) ?? [:]
        }
    }

    private let fileURL: URL
    private var snapshot = Snapshot()
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Keys

    /// Condition key: `process lineage · kind · dimension`. The lineage is
    /// BaselineStore.key(for:) (bundle ID or executable name); the dimension
    /// is the anomaly's drivingMetric (may be empty for e.g. app_hung — the
    /// kind still disambiguates).
    public static func conditionKey(processKey: String, kind: String, dimension: String) -> String {
        "\(processKey)|\(kind)|\(dimension)"
    }

    // MARK: Lifecycle (same pattern as BaselineStore/AnomalyJournal)

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

    // MARK: Mutation

    /// Durable "normal for me": store the envelope for this condition.
    public func acknowledge(
        key: String,
        magnitude: Double,
        envelopeMultiplier: Double,
        processStartAbsTime: UInt64,
        at date: Date = .now
    ) {
        snapshot.records[key] = AcknowledgmentRecord(
            acknowledgedMagnitude: magnitude,
            envelopeMultiplier: envelopeMultiplier,
            ackedAt: date,
            snoozeUntil: nil,
            processStartAbsTime: processStartAbsTime
        )
        save()
    }

    /// Time-boxed snooze. Materially-worse still breaks through (anti-mute);
    /// expiry while the condition is still active re-surfaces it.
    public func snooze(
        key: String,
        until: Date,
        magnitude: Double,
        envelopeMultiplier: Double,
        processStartAbsTime: UInt64,
        at date: Date = .now
    ) {
        snapshot.records[key] = AcknowledgmentRecord(
            acknowledgedMagnitude: magnitude,
            envelopeMultiplier: envelopeMultiplier,
            ackedAt: date,
            snoozeUntil: until,
            processStartAbsTime: processStartAbsTime
        )
        save()
    }

    public func record(forKey key: String) -> AcknowledgmentRecord? {
        snapshot.records[key]
    }

    public func remove(forKey key: String) {
        snapshot.records[key] = nil
        save()
    }

    public var count: Int { snapshot.records.count }

    // MARK: Decision

    /// The pure re-alert decision (unit-testable without the actor).
    /// Re-alert fires when ANY of:
    ///   • materially worse — magnitude > acknowledged × envelopeMultiplier,
    ///   • new instance — the process restarted (startAbsTime differs),
    ///   • snooze expired while the condition is still active.
    /// A new kind/dimension is a different condition key → no record →
    /// `.notAcknowledged` (surfaces normally) — the fourth leg falls out of
    /// the keying.
    public static func evaluate(
        record: AcknowledgmentRecord?,
        currentMagnitude: Double,
        processStartAbsTime: UInt64,
        now: Date = .now
    ) -> ReAlertDecision {
        guard let record else { return .notAcknowledged }
        if record.processStartAbsTime != processStartAbsTime {
            return .realert(.newInstance)
        }
        let materiallyWorse = currentMagnitude > record.acknowledgedMagnitude * record.envelopeMultiplier
        if let snoozeUntil = record.snoozeUntil {
            if now >= snoozeUntil { return .realert(.snoozeExpired) }
            if materiallyWorse { return .realert(.materiallyWorse) }
            return .suppress
        }
        if materiallyWorse { return .realert(.materiallyWorse) }
        return .suppress
    }

    /// Evaluate AND spend the record when it re-alerts: a fired re-alert must
    /// never suppress again (or a dismissed "returned, worse" card would
    /// bounce straight back into silence — the mute the whole design forbids).
    public func decide(
        key: String,
        currentMagnitude: Double,
        processStartAbsTime: UInt64,
        now: Date = .now
    ) -> ReAlertDecision {
        let decision = Self.evaluate(
            record: snapshot.records[key],
            currentMagnitude: currentMagnitude,
            processStartAbsTime: processStartAbsTime,
            now: now
        )
        if case .realert = decision {
            snapshot.records[key] = nil
            save()
        }
        return decision
    }
}

// MARK: - Sensor status (App Group wire shape, written each tick)

/// The small status JSON the app writes to the App Group container each tick
/// and the widget/intents read. State-driven, not polling — the widget
/// timeline reflects this snapshot and costs nothing while quiet.
public struct SensorStatus: Codable, Sendable, Equatable {
    /// The one card the widget shows when something needs attention — the
    /// top surfaced (high-confidence) anomaly, plain language only.
    public struct TopCard: Codable, Sendable, Equatable {
        public var processName: String
        public var kind: String
        /// One-line plain summary (card.whatItIs — already human).
        public var summary: String
        public var safetyTier: Int
        /// Condition key for the widget's Snooze / "Normal for me" intents.
        public var conditionKey: String
        /// The "returned, worse" marker (anti-mute re-alert).
        public var returnedWorse: Bool

        public init(processName: String, kind: String, summary: String, safetyTier: Int, conditionKey: String, returnedWorse: Bool = false) {
            self.processName = processName
            self.kind = kind
            self.summary = summary
            self.safetyTier = safetyTier
            self.conditionKey = conditionKey
            self.returnedWorse = returnedWorse
        }

        enum CodingKeys: String, CodingKey {
            case processName, kind, summary, safetyTier, conditionKey, returnedWorse
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            processName = try c.decodeIfPresent(String.self, forKey: .processName) ?? "?"
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            safetyTier = try c.decodeIfPresent(Int.self, forKey: .safetyTier) ?? 3
            conditionKey = try c.decodeIfPresent(String.self, forKey: .conditionKey) ?? ""
            returnedWorse = try c.decodeIfPresent(Bool.self, forKey: .returnedWorse) ?? false
        }
    }

    public var schemaVersion: Int
    public var updatedAt: Date
    public var monitoringEnabled: Bool
    /// Surfaced (high-confidence) anomaly count.
    public var activeCount: Int
    /// This tick's medium/low-confidence quiet findings.
    public var quietCount: Int
    public var watchedProcessCount: Int
    public var topCard: TopCard?

    public init(
        updatedAt: Date = .now,
        monitoringEnabled: Bool = true,
        activeCount: Int = 0,
        quietCount: Int = 0,
        watchedProcessCount: Int = 0,
        topCard: TopCard? = nil
    ) {
        self.schemaVersion = 1
        self.updatedAt = updatedAt
        self.monitoringEnabled = monitoringEnabled
        self.activeCount = activeCount
        self.quietCount = quietCount
        self.watchedProcessCount = watchedProcessCount
        self.topCard = topCard
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, monitoringEnabled, activeCount, quietCount, watchedProcessCount, topCard
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        monitoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
        activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount) ?? 0
        quietCount = try c.decodeIfPresent(Int.self, forKey: .quietCount) ?? 0
        watchedProcessCount = try c.decodeIfPresent(Int.self, forKey: .watchedProcessCount) ?? 0
        topCard = try c.decodeIfPresent(TopCard.self, forKey: .topCard)
    }

    // MARK: App Group plumbing

    public static let appGroupID = "7JQGQ7CRH8.bot.anomalous.sensor"
    public static let fileName = "status.json"
    /// Distributed-notification name the widget/intents post to nudge the
    /// running app (name-only — a sandboxed appex may not attach userInfo).
    public static let commandNotification = "bot.anomalous.sensor.command"

    public static func fileURL(in containerURL: URL) -> URL {
        containerURL.appending(path: fileName)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> SensorStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SensorStatus.self, from: data)
    }

    /// The Siri/Spotlight answer to "is my Mac behaving normally?" — one
    /// honest sentence, quiet by default. (baselineDeviation never renders
    /// here — plain counts only, so no ±inf formatting hazard.)
    public var summaryLine: String {
        guard monitoringEnabled else {
            return "Monitoring is paused. Nothing is being watched right now."
        }
        if activeCount == 0 {
            let quiet = quietCount > 0
                ? " \(quietCount) low-confidence observation\(quietCount == 1 ? "" : "s") stayed below the alert bar."
                : ""
            return "Yes — all systems nominal. Watching \(watchedProcessCount) processes.\(quiet)"
        }
        var line = "\(activeCount) anomal\(activeCount == 1 ? "y" : "ies") need\(activeCount == 1 ? "s" : "") attention."
        if let top = topCard {
            line += " Top: \(top.processName) — \(top.summary)"
        }
        return line
    }
}

// MARK: - Widget → app commands

/// A user action taken in the widget/Control Center process, queued in the
/// App Group container for the app to apply (the appex can't touch AppState).
/// The app drains the queue on a distributed-notification nudge and at each
/// tick (belt and suspenders).
public struct WidgetCommand: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case acknowledge       // "Normal for me" on a condition
        case snoozeCondition   // time-boxed snooze on a condition
        case snoozeAll         // global alert snooze
        case runScan
        case setMonitoring
    }

    public var action: Action
    public var conditionKey: String?
    public var snoozeSeconds: TimeInterval?
    public var monitoringEnabled: Bool?
    public var issuedAt: Date
    /// Per-command random value — anchors replay rejection (a resent command
    /// carries a nonce the app has already spent). Empty until `signed(with:)`.
    public var nonce: String
    /// base64 HMAC-SHA256 over `canonicalSigningString()` with the shared
    /// Keychain-held key. `nil` on an unsigned (forged) command → rejected.
    public var mac: String?

    public init(
        action: Action,
        conditionKey: String? = nil,
        snoozeSeconds: TimeInterval? = nil,
        monitoringEnabled: Bool? = nil,
        issuedAt: Date = .now,
        nonce: String = "",
        mac: String? = nil
    ) {
        self.action = action
        self.conditionKey = conditionKey
        self.snoozeSeconds = snoozeSeconds
        self.monitoringEnabled = monitoringEnabled
        self.issuedAt = issuedAt
        self.nonce = nonce
        self.mac = mac
    }

    enum CodingKeys: String, CodingKey {
        case action, conditionKey, snoozeSeconds, monitoringEnabled, issuedAt, nonce, mac
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(Action.self, forKey: .action)
        conditionKey = try c.decodeIfPresent(String.self, forKey: .conditionKey)
        snoozeSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .snoozeSeconds)
        monitoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .monitoringEnabled)
        issuedAt = try c.decodeIfPresent(Date.self, forKey: .issuedAt) ?? .now
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce) ?? ""
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
    }

    public static let fileName = "commands.json"

    public static func fileURL(in containerURL: URL) -> URL {
        containerURL.appending(path: fileName)
    }

    /// Append a command to the queue file (last-writer-wins races are
    /// acceptable: commands are rare, user-initiated, and idempotent).
    public static func enqueue(_ command: WidgetCommand, at url: URL) {
        var queue = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([WidgetCommand].self, from: $0) } ?? []
        queue.append(command)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Read and clear the queue (the app consumes; stale commands >10 min old
    /// are dropped — a snooze tapped yesterday must not fire today).
    public static func drain(at url: URL, now: Date = .now) -> [WidgetCommand] {
        guard let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode([WidgetCommand].self, from: data)
        else { return [] }
        try? FileManager.default.removeItem(at: url)
        return queue.filter { now.timeIntervalSince($0.issuedAt) < 600 }
    }

    // MARK: - Authentication (HMAC over the App Group command channel)
    //
    // The App Group container is user-domain and the app is NOT sandboxed, so
    // any same-user process can drop a `commands.json`. Unauthenticated, that
    // lets malware disable monitoring, self-whitelist into the baseline, mute
    // alerts for a century, or replay a captured command. Every legitimate
    // command is therefore MAC'd with a per-install key the widget and app
    // share through a Keychain access group (same Team → readable; other-team
    // or unsigned malware → denied). The app verifies before executing.

    /// Longest snooze the app will honor — a century-long mute (#4) is clamped
    /// to a day regardless of what the command claims. Defense in depth even
    /// for an authentic-but-oversized value.
    public static let maxSnoozeSeconds: TimeInterval = 86_400

    /// The snooze to actually apply: the command's value clamped to
    /// `[0, maxSnoozeSeconds]`, or `def` when the command omits one.
    public func clampedSnoozeSeconds(default def: TimeInterval) -> TimeInterval {
        min(max(0, snoozeSeconds ?? def), Self.maxSnoozeSeconds)
    }

    /// The exact bytes the MAC covers — every field an attacker could bend, in
    /// a JSON array so a `conditionKey` that legitimately contains the field
    /// delimiter (`process|kind|dim`) can't be smuggled across a boundary.
    /// Both processes build this identically from the same-typed fields, so a
    /// JSON round-trip of the command yields a byte-identical signing string.
    func canonicalSigningString() -> String {
        let fields = [
            action.rawValue,
            conditionKey ?? "",
            snoozeSeconds.map { String($0) } ?? "",
            monitoringEnabled.map { $0 ? "true" : "false" } ?? "",
            String(issuedAt.timeIntervalSinceReferenceDate),
            nonce,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(fields) else {
            return fields.joined(separator: "\u{1F}")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A copy stamped with a fresh nonce and a valid MAC for `key`. The widget
    /// calls this when enqueuing; the nonce is regenerated per call so two
    /// identical actions never share a nonce (and can't cancel each other out
    /// at the replay gate).
    public func signed(with key: Data) -> WidgetCommand {
        var copy = self
        copy.nonce = UUID().uuidString
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(copy.canonicalSigningString().utf8),
            using: SymmetricKey(data: key)
        )
        copy.mac = Data(code).base64EncodedString()
        return copy
    }

    /// Whether this command's MAC matches `key` over its own fields — the
    /// constant-time check the app runs before executing. A missing/garbage
    /// MAC, a wrong key, or any tampered field fails.
    public func isAuthentic(key: Data) -> Bool {
        guard let mac, let macBytes = Data(base64Encoded: mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            macBytes,
            authenticating: Data(canonicalSigningString().utf8),
            using: SymmetricKey(data: key)
        )
    }
}

// MARK: - Replay defense (seen-nonce ring)

/// A bounded, on-disk set of already-spent command nonces. Lives in the app's
/// OWN Application Support — NOT the shared App Group container — so an
/// attacker who forges commands can't also erase the record that a nonce was
/// spent. Stateless in memory (each `claim` reads + rewrites the file), so it
/// is safe to use from any isolation domain without a lock.
public struct SeenNonceStore: Sendable {
    public let fileURL: URL
    public let capacity: Int

    public init(fileURL: URL, capacity: Int = 256) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    /// Records `nonce` and returns `true` if it is NEW; returns `false` for an
    /// empty nonce or one already seen (a replay). FIFO-trimmed to `capacity`.
    @discardableResult
    public func claim(_ nonce: String) -> Bool {
        guard !nonce.isEmpty else { return false }
        var seen = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        guard !seen.contains(nonce) else { return false }
        seen.append(nonce)
        if seen.count > capacity { seen.removeFirst(seen.count - capacity) }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(seen) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return true
    }
}

// MARK: - Shared HMAC key (Keychain access group)

/// The per-install secret that authenticates the App Group command channel,
/// held in a Keychain access group both the app and the widget belong to
/// (`<team>.bot.anomalous.sensor.shared`). Same Team + access group → the
/// widget can read the key the app minted; a different-team or unsigned
/// process (malware) is denied by the Keychain, so it can never compute a
/// valid MAC. `kSecAttrAccessibleAfterFirstUnlock` lets the background app and
/// widget read it without an interactive unlock.
public enum SharedSecret {
    /// Team-qualified access group — must match the `keychain-access-groups`
    /// entitlement on BOTH targets (`$(AppIdentifierPrefix)` expands to the
    /// team prefix already used by the App Group id).
    public static let accessGroup = "7JQGQ7CRH8.bot.anomalous.sensor.shared"
    private static let service = "bot.anomalous.sensor.shared"
    private static let account = "widget-command-hmac-key"
    private static let keyByteCount = 32

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// The shared key, minting a fresh 32-byte one on first use when
    /// `createIfMissing` is set (the app does; the widget only reads). Returns
    /// nil if absent-and-read-only, or if the Keychain is unavailable (e.g. an
    /// unsigned build with no entitlement) — callers fail closed.
    public static func key(createIfMissing: Bool) -> Data? {
        if let existing = load() { return existing }
        guard createIfMissing else { return nil }
        var bytes = Data(count: keyByteCount)
        let ok = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, keyByteCount, $0.baseAddress!) }
        guard ok == errSecSuccess else { return nil }
        store(bytes)
        // Re-read so a benign race (both processes create) converges on the
        // one row the Keychain actually kept.
        return load() ?? bytes
    }

    private static func load() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    private static func store(_ data: Data) {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
