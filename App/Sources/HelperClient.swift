import Foundation
import ServiceManagement
import AnomalousCore

/// Non-isolated XPC transport to the root helper. Kept OFF the main actor on
/// purpose: NSXPCConnection invokes reply/error handlers on a background
/// queue, so any closure that inherited @MainActor isolation would trap the
/// concurrency runtime (`_dispatch_assert_queue_fail`) when XPC calls out.
/// Everything here is nonisolated; results hop back to the main actor at the
/// await boundary in HelperClient.
/// Resume a continuation EXACTLY once — whichever of {reply, XPC error,
/// timeout} arrives first. Prevents both a hang (never resumed) and a crash
/// (resumed twice).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: value)
    }
}

private final class HelperConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// Reuse/create the connection and return a proxy whose XPC failures are
    /// delivered to `onError`. CRITICAL: without an error handler that resumes
    /// the caller, a broken/rejected connection makes the reply block never
    /// fire and the `await` hang forever — which freezes the entire monitoring
    /// tick (no detection, no cards, banner stuck "off").
    private func makeProxy(onError: @escaping @Sendable (Error) -> Void) -> AnomalousHelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            // The server end is deliberately NOT pinned client-side: launchd
            // owning the privileged Mach service name already blocks impostors.
            // The strong control is the HELPER pinning its clients.
            c.remoteObjectInterface = NSXPCInterface(with: AnomalousHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.connection = nil; self.lock.unlock()
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? AnomalousHelperProtocol
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    /// Root-wide sample. Returns nil (NEVER hangs) if the helper is unreachable:
    /// an XPC error OR a 5s timeout resumes the caller. A hung helper must never
    /// block the tick.
    func sampleAll() async -> [ProcessSample]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[ProcessSample]?, Never>) in
            let once = ResumeOnce(continuation)
            guard let proxy = makeProxy(onError: { _ in once.resume(nil) }) else { once.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(nil) }
            proxy.sampleAll { data in
                once.resume(data.flatMap { try? JSONDecoder().decode([ProcessSample].self, from: $0) })
            }
        }
    }

    func terminate(pid: Int32, startAbsTime: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            guard let proxy = makeProxy(onError: { _ in once.resume(false) }) else { once.resume(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(false) }
            proxy.terminate(pid: pid, expectedStartAbsTime: startAbsTime) { code in
                once.resume(code == 0)
            }
        }
    }
}

/// App-side of the privileged helper: installs it (one System Settings
/// approval — not a password prompt), and exposes root-wide sampling + root
/// termination. Degrades gracefully — when the helper isn't reachable, the
/// app falls back to unprivileged user-only sampling, so it never *requires*
/// root and is useful before the user ever elevates.
@MainActor
@Observable
final class HelperClient {
    enum Status: Equatable { case notInstalled, requiresApproval, installed, failed(String) }

    private(set) var status: Status = .notInstalled
    /// True once a helper sample has actually succeeded — reflects the root
    /// service being reachable however it was installed.
    private(set) var active = false
    private let transport = HelperConnection()
    /// Short-lived poll that watches for the user's System Settings approval
    /// (macOS never calls back when they flip the toggle).
    private var approvalPoll: Task<Void, Never>?

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    func refreshStatus() {
        switch service.status {
        case .enabled: status = .installed
        case .requiresApproval: status = .requiresApproval
        case .notRegistered, .notFound: status = .notInstalled
        @unknown default: status = .notInstalled
        }
    }

    /// Register the LaunchDaemon. Triggers a one-time System Settings
    /// approval (Login Items & Extensions); on approval macOS runs the
    /// helper as root. Requires the app to be Developer ID-signed + notarized.
    func install() {
        do {
            try service.register()
        } catch {
            // "Already registered" / "operation in progress" are NOT real
            // failures — fall through to the true status. Only surface an
            // error if we genuinely can't tell where we stand.
            refreshStatus()
            if status == .notInstalled { status = .failed(error.localizedDescription) }
            beginApprovalPolling()
            return
        }
        refreshStatus()
        beginApprovalPolling()
    }

    /// Open Login Items & Extensions AND start watching for approval — macOS
    /// won't call back when the user flips the toggle, so we poll.
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
        beginApprovalPolling()
    }

    /// Re-check when the app regains focus (user just came back from System
    /// Settings). Keeps the "Approve…" row from lying after they approve.
    func refreshOnActivate() {
        refreshStatus()
        if status == .requiresApproval || status == .installed { beginApprovalPolling(for: 20) }
    }

    /// Poll status (and, once enabled, a live sample) so the UI flips to
    /// Installed the moment the user approves — instead of staying stuck on
    /// "Approve…" until the next 90s monitoring tick. Self-cancels on success.
    func beginApprovalPolling(for seconds: Int = 150) {
        approvalPoll?.cancel()
        approvalPoll = Task { @MainActor [weak self] in
            var elapsed = 0
            while elapsed < seconds {
                guard let self, !Task.isCancelled else { return }
                self.refreshStatus()
                if self.status == .installed {
                    _ = await self.sampleAll()          // sets `active` once reachable
                    if self.active { return }
                }
                try? await Task.sleep(for: .seconds(2))
                elapsed += 2
            }
        }
    }

    func uninstall() {
        approvalPoll?.cancel()
        try? service.unregister()
        transport.invalidate()
        active = false
        refreshStatus()
    }

    /// Root-wide sample, or nil if the helper is unavailable (caller falls
    /// back to unprivileged sampling).
    func sampleAll() async -> [ProcessSample]? {
        let samples = await transport.sampleAll()
        active = (samples != nil)
        return samples
    }

    /// Root termination with the pid-reuse guard enforced inside the helper.
    func terminate(_ identity: ProcessIdentity) async -> Bool {
        await transport.terminate(pid: identity.pid, startAbsTime: identity.startAbsTime)
    }
}
