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
