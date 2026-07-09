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

    // MARK: - Release-channel identity

    /// Known release-channel suffixes on a bundle id. A channel is a
    /// distribution track (pre-release, debug), NOT a different app:
    /// `dev.zed.Zed-Preview` is the same software as `dev.zed.Zed`. Treating the
    /// raw suffixed id as a distinct identity — or letting the model read the
    /// suffix as a *description* — is the "Zed-Preview → 'a preview tool'"
    /// hallucination. Collapsing the variants to one canonical id fixes both.
    static let releaseChannelTokens = ["Preview", "Nightly", "Beta", "Alpha", "Canary", "Dev", "Debug", "RC", "Insiders", "EAP"]

    /// Split the bundle id into its canonical (channel-stripped) form and the
    /// channel token, if any. ONE implementation so `releaseChannel` and
    /// `canonicalBundleID` can never disagree. Handles both spellings seen in
    /// the wild: a dash-attached suffix (`dev.zed.Zed-Preview`) and a channel
    /// as its own trailing segment (`com.brave.Browser.beta`).
    private func channelSplit() -> (canonical: String, channel: String?)? {
        guard let bundleID else { return nil }
        var segments = bundleID.split(separator: ".").map(String.init)
        guard let leaf = segments.last else { return (bundleID, nil) }
        // Channel as its own trailing segment: com.brave.Browser.beta
        if segments.count > 1, let token = Self.channelToken(leaf) {
            segments.removeLast()
            return (segments.joined(separator: "."), token)
        }
        // Channel dash-attached to the leaf: dev.zed.Zed-Preview
        if let dash = leaf.range(of: "-", options: .backwards),
           let token = Self.channelToken(String(leaf[dash.upperBound...])) {
            segments[segments.count - 1] = String(leaf[..<dash.lowerBound])
            return (segments.joined(separator: "."), token)
        }
        return (bundleID, nil)
    }

    private static func channelToken(_ s: String) -> String? {
        releaseChannelTokens.first { $0.caseInsensitiveCompare(s) == .orderedSame }
    }

    /// The release channel named by the bundle id's suffix, if any (e.g.
    /// "Preview" for `dev.zed.Zed-Preview`). Nil for release builds and bare
    /// executables.
    public var releaseChannel: String? { channelSplit()?.channel }

    /// The bundle id with any release-channel suffix stripped, so channel
    /// variants share one canonical identity. Equals `bundleID` when there is
    /// no recognized channel suffix; nil only for bare executables.
    public var canonicalBundleID: String? { channelSplit()?.canonical }

    /// The base app name implied by the bundle id — its canonical last segment
    /// (e.g. "Zed" for `dev.zed.Zed-Preview`). The bridge back to a corpus
    /// record keyed by process name when the observed executable name diverges.
    public var canonicalBundleLeaf: String? {
        canonicalBundleID?.split(separator: ".").last.map(String.init)
    }
}
