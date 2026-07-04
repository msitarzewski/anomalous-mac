import Foundation
import Darwin

/// What the action layer can offer for an anomaly, gated by safety tier.
/// Conservative by default: a confident wrong kill button is worse than no
/// button (memory-bank projectRules). Tiers come from the knowledge map /
/// diagnosis card; this type maps a card to a concrete, reversible verb.
public enum ProcessAction: Sendable, Equatable {
    /// Tier 1: terminate; the OS/launchd brings it back or it's the user's own.
    case terminate
    /// Tier 1 for user apps: quit and relaunch (reclaims leaked memory).
    case restartApp
    /// Tier 1: open the app's update path (no kill).
    case update
    /// Tier 3: nothing safe to offer — explain only.
    case explainOnly

    public var isDestructive: Bool {
        switch self {
        case .terminate, .restartApp: return true
        case .update, .explainOnly: return false
        }
    }

    public var verb: String {
        switch self {
        case .terminate: return "Quit"
        case .restartApp: return "Restart"
        case .update: return "Update"
        case .explainOnly: return "No safe action"
        }
    }

    /// Derive the offered action from the card's safety tier + anomaly kind.
    /// Tier ≥ 3 (or unknown) always → explainOnly.
    public static func offered(tier: Int, kind: Anomaly.Kind, isApp: Bool) -> ProcessAction {
        guard tier == 1 else { return .explainOnly }
        switch kind {
        case .rssLeak, .rssCeiling: return isApp ? .restartApp : .terminate
        default: return .terminate
        }
    }
}

/// Executes actions on user-owned / launchd-respawned processes only.
/// Never attempts privilege escalation — root daemons surface the
/// `sudo killall` command to copy instead (v1 punts, per the seed).
public struct ProcessActuator: Sendable {
    public init() {}

    public enum ActuationError: Error, Equatable {
        case notPermitted    // EPERM — needs privilege we won't escalate to
        case noSuchProcess   // ESRCH — already gone (arguably success)
        case identityChanged // pid now belongs to a DIFFERENT process (reuse)
        case unsupported
    }

    /// Sends SIGTERM (graceful) — but ONLY after confirming the pid still
    /// belongs to the process we flagged. Time can pass between detection and
    /// the user clicking the button; pids get reused. Re-reading the live
    /// start time and comparing to the flagged identity's makes a confident
    /// wrong kill impossible (projectRules: conservative by default).
    @discardableResult
    public func terminate(identity: ProcessIdentity, force: Bool = false) -> Result<Void, ActuationError> {
        guard let live = Collector.rusage(for: identity.pid) else {
            return .failure(.noSuchProcess)
        }
        guard live.startAbsTime == identity.startAbsTime else {
            return .failure(.identityChanged)
        }
        // SIGTERM (graceful "Quit") by default; SIGKILL ("Force Quit") only
        // when the user explicitly escalates.
        guard kill(identity.pid, force ? SIGKILL : SIGTERM) == 0 else {
            switch errno {
            case EPERM: return .failure(.notPermitted)
            case ESRCH: return .failure(.noSuchProcess)
            default: return .failure(.unsupported)
            }
        }
        return .success(())
    }

    /// The copy-paste fallback for root/privileged processes.
    public func manualCommand(forExecutable name: String) -> String {
        "sudo killall \(name)"
    }
}
