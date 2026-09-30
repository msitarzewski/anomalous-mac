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
        return loopbackHosts.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// Whether a dev-server override URL is permitted for the given build.
    /// Release: loopback only. Debug: any URL with a resolvable host (LAN dev
    /// servers, etc.). `isDebug` is injected so the decision is testable for
    /// both configurations from a single (debug) test build.
    public static func isAllowedOverride(_ urlString: String, isDebug: Bool) -> Bool {
        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        return isDebug || isLoopback(urlString)
    }
    /// Environment configuration is a debug capability, never a release bypass.
    public static func resolve(environment: String?, developerOverride: String?, isDebug: Bool) -> String {
        if isDebug, let environment, isAllowedOverride(environment, isDebug: true) {
            return environment
        }
        if let developerOverride, isAllowedOverride(developerOverride, isDebug: isDebug) {
            return developerOverride
        }
        return "https://api.anomalous.bot"
    }

    public enum TransportError: Error { case insecureURL }

    public static func assertSecureTransport(_ url: URL) throws {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && isLoopback(url.absoluteString)) else {
            throw TransportError.insecureURL
        }
    }

    /// API redirects are refused: configuration must name the intended endpoint.
    /// This prevents an HTTPS response redirecting credentials or payloads elsewhere.
    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw TransportError.insecureURL }
        try assertSecureTransport(url)
        return try await session.data(for: request)
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectRefusal(), delegateQueue: nil)
}

private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
