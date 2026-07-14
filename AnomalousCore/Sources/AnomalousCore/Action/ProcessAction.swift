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
        // Tier 3 is "do not act" (unknown / root / data-holding) → explain only,
        // no button. Tiers 1 AND 2 offer the action — tier 2 is "caution," which
        // the card styles accordingly, not "hide the button" (which left cards
        // whose own verdict said "quit it" with no way to do it).
        guard tier <= 2 else { return .explainOnly }
        // An app is quit-and-reopened (Restart — matches "quit it and reopen X");
        // a background helper is quit (Quit — macOS respawns it).
        return isApp ? .restartApp : .terminate
    }

    /// Aggressiveness rank, SAFEST first — the total order reconciliation uses.
    /// `explainOnly` (do nothing) < `update` (no kill) < `restartApp` (quit +
    /// relaunch the user's own app) < `terminate` (signal a process). Force
    /// (SIGKILL) is a separate flag on the terminate path, not a rank here.
    private var aggression: Int {
        switch self {
        case .explainOnly: return 0
        case .update: return 1
        case .restartApp: return 2
        case .terminate: return 3
        }
    }

    /// Map the server's `safe_action` enum → a concrete action. The LLM's
    /// constrained choice: quit/force_quit → terminate (the force flag rides the
    /// existing terminate path, not the enum), restart → restartApp, update →
    /// update, none → explainOnly. Unknown/nil → nil (no opinion).
    public static func from(safeAction: String?) -> ProcessAction? {
        switch safeAction?.lowercased() {
        case "quit", "force_quit": return .terminate
        case "restart": return .restartApp
        case "update": return .update
        case "none": return .explainOnly
        default: return nil
        }
    }

    /// Take-the-safer reconciliation: the LLM can only make the offered action
    /// SAFER, never more aggressive. Returns the LESS aggressive of the model's
    /// choice and the deterministic offer. A nil `llm` (no opinion / unknown
    /// enum) leaves the deterministic offer untouched. Identity stays identity —
    /// this governs the ACTION only.
    public static func reconciled(llm: ProcessAction?, deterministic: ProcessAction) -> ProcessAction {
        guard let llm else { return deterministic }
        return llm.aggression <= deterministic.aggression ? llm : deterministic
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
