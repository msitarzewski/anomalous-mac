import Foundation
import Testing
@testable import AnomalousCore

/// The dev-server override's safety property — a release build can only be
/// pointed at the user's own machine — is the shared `ServerOverridePolicy`, so
/// the release restriction is testable from a debug test build by injecting the
/// build configuration.
@Suite("server override policy — the dev-server loopback restriction")
struct ServerOverridePolicyTests {
    @Test("loopback hosts are recognized; remote hosts are not")
    func loopbackDetection() {
        #expect(ServerOverridePolicy.isLoopback("http://localhost:8091"))
        #expect(ServerOverridePolicy.isLoopback("http://127.0.0.1:8091"))
        #expect(ServerOverridePolicy.isLoopback("http://[::1]:8091"))
        #expect(!ServerOverridePolicy.isLoopback("http://example.com:8091"))
        #expect(!ServerOverridePolicy.isLoopback("https://api.anomalous.bot"))
        #expect(!ServerOverridePolicy.isLoopback("http://1.1.1.1"))
        #expect(!ServerOverridePolicy.isLoopback("not-a-url"))
    }

    @Test("RELEASE builds accept ONLY a loopback override — never a remote host")
    func releaseIsLoopbackOnly() {
        #expect(ServerOverridePolicy.isAllowedOverride("http://localhost:8091", isDebug: false))
        #expect(ServerOverridePolicy.isAllowedOverride("http://127.0.0.1:8091", isDebug: false))
        // The property that protects a shipped app: a remote host is rejected,
        // so the token and triage payloads can never be redirected off-device.
        #expect(!ServerOverridePolicy.isAllowedOverride("http://example.com:8091", isDebug: false))
        #expect(!ServerOverridePolicy.isAllowedOverride("https://evil.example", isDebug: false))
        #expect(!ServerOverridePolicy.isAllowedOverride("http://1.1.1.1", isDebug: false))
    }

    @Test("DEBUG builds allow any resolvable host (LAN dev servers) but still reject garbage")
    func debugAllowsAnyHost() {
        #expect(ServerOverridePolicy.isAllowedOverride("http://192.168.1.50:8091", isDebug: true))
        #expect(ServerOverridePolicy.isAllowedOverride("http://example.com", isDebug: true))
        #expect(!ServerOverridePolicy.isAllowedOverride("not-a-url", isDebug: true))
    }
}

@Suite("release configuration and transport")
struct ReleaseTransportTests {
    @Test func environmentCannotOverrideRelease() {
        for value in ["http://evil.example", "https://evil.example", "http://localhost:8787"] {
            #expect(ServerOverridePolicy.resolve(environment: value, developerOverride: nil, isDebug: false) == "https://api.anomalous.bot")
        }
        #expect(ServerOverridePolicy.resolve(environment: "https://evil.example", developerOverride: "http://localhost:8787", isDebug: false) == "http://localhost:8787")
        #expect(ServerOverridePolicy.resolve(environment: "http://localhost:8787", developerOverride: nil, isDebug: true) == "http://localhost:8787")
    }

    @Test func rejectsNonWebAndCredentialURLs() {
        for value in ["ftp://localhost/file", "file://localhost/file", "https://user:pass@example.com", "https://example.com?token=x"] {
            #expect(!ServerOverridePolicy.isAllowedOverride(value, isDebug: true))
        }
        #expect(ServerOverridePolicy.isAllowedOverride("http://[::1]:8787", isDebug: false))
    }

    @Test func transportRejectsBeforeNetwork() async throws {
        for value in ["http://example.com", "ftp://localhost/file", "https://user:pass@example.com"] {
            do {
                _ = try await ServerOverridePolicy.data(for: URLRequest(url: URL(string: value)!))
                Issue.record("unsafe transport accepted")
            } catch ServerOverridePolicy.TransportError.insecureURL { }
        }
        try ServerOverridePolicy.assertSecureTransport(URL(string: "http://[::1]:8787")!)
        try ServerOverridePolicy.assertSecureTransport(URL(string: "https://api.anomalous.bot")!)
    }
}
