import Foundation

/// The pure policy for what host a developer server override may point at. The
/// safety property of the hidden dev switch is here — a release build restricts
/// the override to a LOOPBACK host, so a shipped app can be aimed at the user's
/// OWN machine for local testing but never redirected to a remote server that
/// would capture the account token or triage payloads. Keeping the allowlist a
/// pure function (not inline behind `#if DEBUG`) is what makes the release
/// restriction unit-testable — the same predicate the release build enforces is
/// the one under test.
public enum ServerOverridePolicy {
    /// Hosts that resolve to this machine only.
    public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// True iff the URL's host is a loopback host — the release restriction.
    public static func isLoopback(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host else { return false }
        return loopbackHosts.contains(host)
    }

    /// Whether a dev-server override URL is permitted for the given build.
    /// Release: loopback only. Debug: any URL with a resolvable host (LAN dev
    /// servers, etc.). `isDebug` is injected so the decision is testable for
    /// both configurations from a single (debug) test build.
    public static func isAllowedOverride(_ urlString: String, isDebug: Bool) -> Bool {
        if isDebug {
            return URL(string: urlString)?.host != nil
        }
        return isLoopback(urlString)
    }
}
