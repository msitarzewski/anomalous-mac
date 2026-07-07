import Foundation

/// The reply codes the root helper returns from `terminate`. Kept a typed enum
/// (raw values are the wire codes the app already switches on) so the policy and
/// its tests share one definition.
public enum TerminationVerdict: Int32, Equatable, Sendable {
    case allowed = 0          // authorized — the helper may SIGTERM
    case identityChanged = 1  // pid-reuse: live start time != caller's expectation
    case noSuchProcess = 2    // the pid is gone
    case notPermitted = 3     // kill() returned EPERM
    case unsupported = 4      // kill() returned another error
    case protectedProcess = 5 // pid <= 1, or a critical/system process
}

/// The pure, deterministic termination policy — the single source of truth for
/// what the root helper is allowed to signal. It performs NO syscalls and does
/// NO killing: the helper re-reads the live start time and name, calls
/// `decide`, and only then (on `.allowed`) issues the SIGTERM. Extracting the
/// decision here means the exact code that guards the root kill is the exact
/// code under test — the guard can't silently drift from its coverage.
public enum TerminationGuard {
    /// Processes the root helper NEVER signals, whatever a caller (or a diagnosis
    /// card, or a server) claims. A root SIGTERM to these is a system
    /// denial-of-service or a disabling of security tooling, never anomaly
    /// remediation. `pid <= 1` (kernel_task=0, launchd=1) is handled separately.
    public static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "logind",
        "securityd", "syslogd", "notifyd", "opendirectoryd", "coreauthd",
        "trustd", "syspolicyd", "endpointsecurityd", "sysmond", "watchdogd",
    ]

    /// Decide whether a termination is authorized. Defense in depth, in order:
    /// (1) never signal pid <= 1; (2) the process must still exist
    /// (`liveStartAbsTime` nil = gone); (3) the pid-reuse guard — the live start
    /// time must match the caller's expectation, or the pid was recycled onto a
    /// different process; (4) never signal a protected critical/system process.
    /// The helper does not trust the caller's pid to be a legitimate target.
    public static func decide(
        pid: Int32,
        expectedStartAbsTime: UInt64,
        liveStartAbsTime: UInt64?,
        name: String
    ) -> TerminationVerdict {
        guard pid > 1 else { return .protectedProcess }
        guard let live = liveStartAbsTime else { return .noSuchProcess }
        guard live == expectedStartAbsTime else { return .identityChanged }
        guard !protectedNames.contains(name) else { return .protectedProcess }
        return .allowed
    }
}
