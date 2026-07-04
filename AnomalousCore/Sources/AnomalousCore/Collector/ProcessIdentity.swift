import Foundation

/// Stable identity for a process across samples. pid + start time survives
/// pid reuse. NOTE (protocol rule): this is the macOS *implementation* of
/// process identity — the wire schemas keep identity abstract so the
/// Windows sensor can use its own shape.
public struct ProcessIdentity: Sendable, Hashable, Codable {
    public let pid: pid_t
    /// Process start time — mach absolute time at exec, from rusage.
    public let startAbsTime: UInt64
    /// Base executable name only. Full paths never leave the collector's
    /// local store (they can contain usernames).
    public let executableName: String
    /// Reverse-DNS bundle ID when the binary lives in a bundle; nil for
    /// bare executables and most daemons.
    public let bundleID: String?
    /// Marketing version from the bundle, when resolvable.
    public let appVersion: String?
    /// How the binary was installed, derived from its (local-only) path.
    public let installSource: InstallSource
    /// Whether the process runs as root — a hard fact for the diagnosis, so
    /// the model never guesses ownership wrong (Homebrew's mysqld is the
    /// user's, not root's).
    public let ownerIsRoot: Bool

    public init(pid: pid_t, startAbsTime: UInt64, executableName: String, bundleID: String? = nil, appVersion: String? = nil, installSource: InstallSource = .other, ownerIsRoot: Bool = false) {
        self.pid = pid
        self.startAbsTime = startAbsTime
        self.executableName = executableName
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.installSource = installSource
        self.ownerIsRoot = ownerIsRoot
    }

    // Resilient decoding: fields added later (installSource) default rather
    // than failing the whole decode, so an app talking to a helper built at a
    // different version never silently loses all data over one missing key.
    enum CodingKeys: String, CodingKey {
        case pid, startAbsTime, executableName, bundleID, appVersion, installSource, ownerIsRoot
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(pid_t.self, forKey: .pid)
        startAbsTime = try c.decode(UInt64.self, forKey: .startAbsTime)
        executableName = try c.decode(String.self, forKey: .executableName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        installSource = try c.decodeIfPresent(InstallSource.self, forKey: .installSource) ?? .other
        ownerIsRoot = try c.decodeIfPresent(Bool.self, forKey: .ownerIsRoot) ?? false
    }
}
