import Foundation

/// The XPC contract between the unprivileged menu-bar app and the root
/// helper. WHY a root helper exists: a non-root process gets EPERM from
/// `proc_pid_rusage` for every root-owned daemon (empirically 0/166 on a
/// real machine) — so dasd, WindowServer, kernel_task, the entire
/// system-daemon tier, are invisible without privilege. The helper samples
/// as root and returns results over XPC; it also performs root-daemon
/// terminations the app itself cannot.
///
/// Kept deliberately tiny (two verbs + version). It reads process rusage
/// and sends SIGTERM — nothing else. A small, auditable root surface is a
/// feature: the whole binary can be read in a sitting.
@objc public protocol AnomalousHelperProtocol {
    /// Sample every process (including root-owned) and reply with a
    /// JSON-encoded `[ProcessSample]`. `Data` (not a custom type) keeps the
    /// XPC interface plist-serializable without registering classes.
    func sampleAll(withReply reply: @escaping (Data?) -> Void)

    /// Terminate a root-owned process — but ONLY after the helper itself
    /// re-validates the pid's live start time against `expectedStartAbsTime`
    /// (pid-reuse guard, same rule the app uses) AND confirms the target is not
    /// a protected critical/system process. Reply codes:
    /// 0 = terminated, 1 = identity changed (refused), 2 = no such process,
    /// 3 = not permitted, 4 = unsupported, 5 = protected (refused).
    func terminate(pid: Int32, expectedStartAbsTime: UInt64, withReply reply: @escaping (Int32) -> Void)

    /// Helper build version — lets the app detect a stale installed helper
    /// after an update and re-register.
    func version(withReply reply: @escaping (String) -> Void)
}

/// Shared identifiers so the app, the helper, and the LaunchDaemon plist
/// never drift out of sync.
public enum HelperConstants {
    /// The Mach service the helper vends and the app connects to. Must match
    /// the LaunchDaemon plist's MachServices key exactly.
    public static let machServiceName = "bot.anomalous.helper"
    /// The LaunchDaemon plist basename registered via SMAppService.daemon.
    public static let daemonPlistName = "bot.anomalous.helper.plist"
    /// Bumped on every helper change so the app can spot a stale install.
    public static let version = "0.1.1"

    /// Apple Developer Team ID. The root helper accepts XPC connections ONLY
    /// from clients signed by this team — so a malicious local process can't
    /// drive the privileged sampler/killer. Also the partner-verification
    /// anchor server-side.
    public static let teamID = "7JQGQ7CRH8"

    /// Code-signing requirement a CLIENT must satisfy to talk to the helper —
    /// pinned to our Team ID AND the app's bundle identifier, so it's "the
    /// genuine Anomalous app", not merely "anything signed by our team".
    public static let clientRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"bot.anomalous.sensor\""

    /// Code-signing requirement the APP applies to the SERVER end of the XPC
    /// connection — pins the helper's identity so the app won't drive an
    /// impostor daemon that somehow claimed the Mach name.
    public static let helperRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"bot.anomalous.helper\""
}
