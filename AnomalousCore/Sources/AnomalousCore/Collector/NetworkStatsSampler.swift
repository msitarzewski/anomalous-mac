import Foundation
import Darwin

/// Per-process network byte counters via `NetworkStatistics.framework` — the
/// private framework behind nettop/Activity Monitor's network columns
/// (Phase 5). The manager streams one "source" per TCP/UDP flow; each source's
/// description carries `processID`, `processName`, `rxBytes`, `txBytes` (and
/// the remote endpoint, unused here — destinations are a future dimension).
///
/// ⚠️ PRIVATE SPI, resolved via dlopen/dlsym in the UnresponsiveProbe house
/// style: any missing symbol or nil manager disables the dimension for the
/// process's lifetime (`isAvailable` false, totals stay empty) — never a
/// crash, never a hang (the snapshot query is semaphore-timed).
///
/// Verified on-device (M5 Max, macOS 27.0, 2026-07-05): unprivileged reads
/// attribute per-pid byte counts for SAME-UID processes only (154 sources,
/// 40 pids, all uid 501; php↔mysqld loopback counters cross-matched exactly).
/// Root-owned daemons' flows are invisible unprivileged — the root helper
/// runs this same sampler, mirroring how rusage covers the root tier.
///
/// Counter semantics: per-flow byte counts are cumulative per SOCKET, and
/// sockets churn. The sampler folds per-source deltas into a MONOTONIC
/// per-pid accumulator ("bytes since sampler start"), so `netBytesIn/Out`
/// behave exactly like the rusage cumulative counters: 0 = unknown (process
/// never seen with a socket), Δ-over-window for rates. Bytes moved between a
/// flow's last refresh and its close are lost — an undercount, never noise.
public final class NetworkStatsSampler: @unchecked Sendable {
    /// One shared instance per process (app AND helper each run their own —
    /// separate processes, separate visibility tiers). @unchecked Sendable:
    /// all mutable state is confined to `queue`; snapshots read via
    /// `queue.sync` (documented discipline, no other access path).
    public static let shared = NetworkStatsSampler()

    public struct Totals: Sendable, Equatable {
        public var bytesIn: UInt64 = 0
        public var bytesOut: UInt64 = 0
    }

    // C/block shapes for the NStat SPI. Blocks cross as AnyObject — passing a
    // Swift closure through a @convention(c) block parameter is marked
    // noescape and aborts when the framework retains it (measured on 27.0);
    // an explicit @convention(block) value cast to AnyObject escapes safely.
    private typealias ManagerCreateFn = @convention(c) (CFAllocator?, AnyObject, AnyObject) -> UnsafeMutableRawPointer?
    private typealias AddAllFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias SourceSetBlockFn = @convention(c) (UnsafeMutableRawPointer, AnyObject) -> Void
    private typealias SourceQueryFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias QueryAllFn = @convention(c) (UnsafeMutableRawPointer, AnyObject) -> Void
    private typealias SourceCallback = @convention(block) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Void
    private typealias DescriptionCallback = @convention(block) (CFDictionary?) -> Void
    private typealias VoidCallback = @convention(block) () -> Void

    private let queue = DispatchQueue(label: "bot.anomalous.nstat")
    // Confined to `queue`:
    private var manager: UnsafeMutableRawPointer?
    private var perSourceLast: [UnsafeMutableRawPointer: (pid: pid_t, rx: UInt64, tx: UInt64)] = [:]
    private var totalsByPID: [pid_t: Totals] = [:]
    private var started = false
    private var available = false
    // Resolved once at setup: the batched COUNTS query. Descriptions carry
    // byte counts only as of source-add/close (measured mid-download: DESC
    // rx=0 while COUNTS rx=8,039,631) — counts are the live read, and their
    // dictionaries carry processID on this build too.
    private var queryAllSources: QueryAllFn?
    // Retained completion blocks for in-flight (and recently-timed-out) COUNTS
    // queries. See snapshotTotals for the ABI reasoning — the framework may
    // call the completion AFTER our timeout returns and does NOT retain it, so
    // it must outlive the call here or a freed block gets invoked. Bounded so
    // it can never grow unbounded; confined to `queue` like all other state.
    private var liveCompletions: [VoidCallback] = []

    public init() {}

    /// Whether the SPI resolved and a manager exists. Forces setup.
    public var isAvailable: Bool {
        queue.sync {
            startIfNeeded()
            return available
        }
    }

    /// One tick's cumulative per-pid totals. Triggers a batched COUNTS
    /// refresh of every live source, waits at most `timeout` for the batch to
    /// complete (a stall returns the previous totals — stale beats hung),
    /// then snapshots the accumulator. Empty when the SPI is unavailable.
    public func snapshotTotals(timeout: TimeInterval = 1.0) -> [pid_t: Totals] {
        let ready: (manager: UnsafeMutableRawPointer, queryAll: QueryAllFn)? = queue.sync {
            startIfNeeded()
            guard available, let manager, let queryAllSources else { return nil }
            return (manager, queryAllSources)
        }
        guard let ready else { return [:] }

        // Refresh outside queue.sync — counts callbacks land ON the queue,
        // so waiting for the completion inside it would deadlock.
        let done = DispatchSemaphore(value: 0)
        let completion: VoidCallback = { done.signal() }
        // ⚠️ ABI: NStatManagerQueryAllSources takes the completion as an
        // unretained @convention(block). On a `timeout` the framework may
        // still invoke it after this method returns; a stack-local block would
        // be freed by then → calling a dead block (EXC_BAD_ACCESS, worse in
        // the root helper). Retain it (and, transitively, the semaphore it
        // captures) on `queue` for well beyond any plausible late callback —
        // one query per ~90s tick, so a ring of 8 spans minutes. Same
        // house-style guard as the removed-block note above.
        queue.sync {
            liveCompletions.append(completion)
            if liveCompletions.count > 8 {
                liveCompletions.removeFirst(liveCompletions.count - 8)
            }
        }
        ready.queryAll(ready.manager, completion as AnyObject)
        _ = done.wait(timeout: .now() + timeout)

        return queue.sync { totalsByPID }
    }

    // MARK: - Setup + accumulation (all on `queue`)

    private func startIfNeeded() {
        guard !started else { return }
        started = true

        guard let lib = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY) else { return }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(lib, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let create = symbol("NStatManagerCreate", as: ManagerCreateFn.self),
              let addTCP = symbol("NStatManagerAddAllTCP", as: AddAllFn.self),
              let addUDP = symbol("NStatManagerAddAllUDP", as: AddAllFn.self),
              let setDescription = symbol("NStatSourceSetDescriptionBlock", as: SourceSetBlockFn.self),
              let setCounts = symbol("NStatSourceSetCountsBlock", as: SourceSetBlockFn.self),
              let setRemoved = symbol("NStatSourceSetRemovedBlock", as: SourceSetBlockFn.self),
              let queryDescription = symbol("NStatSourceQueryDescription", as: SourceQueryFn.self),
              let queryAll = symbol("NStatManagerQueryAllSources", as: QueryAllFn.self)
        else { return }
        queryAllSources = queryAll

        // Source callback fires on `queue` for every existing + new flow.
        let onSource: SourceCallback = { [weak self] source, _ in
            guard let self else { return }
            // Counts are the live byte path; the description (queried once at
            // add) is the pid-mapping fallback should a future build drop
            // processID from counts payloads — both route through `ingest`,
            // whose per-source monotonic guard makes double delivery harmless.
            let onReading: DescriptionCallback = { [weak self] reading in
                self?.ingest(source: source, reading: reading as? [String: Any])
            }
            // ⚠️ The removed block is ZERO-arg (`void (^)(void)`) — registering
            // a 1-arg block here made the framework's thunk retain a garbage
            // register the first time a socket closed (EXC_BAD_ACCESS in
            // objc_retain; caught by the on-device probe, the hung-probe
            // lesson replayed). The source is captured, used only as a map
            // key, never dereferenced.
            let onRemoved: VoidCallback = { [weak self] in
                self?.perSourceLast[source] = nil
            }
            setDescription(source, onReading as AnyObject)
            setCounts(source, onReading as AnyObject)
            setRemoved(source, onRemoved as AnyObject)
            queryDescription(source)
        }
        guard let manager = create(kCFAllocatorDefault, queue as AnyObject, onSource as AnyObject) else { return }
        self.manager = manager
        addTCP(manager)
        addUDP(manager)
        available = true
    }

    /// Fold one source reading (counts or description payload — same keys)
    /// into the per-pid accumulator: delta since this source's last reading
    /// (never negative — a shrunk counter is a shape surprise and reads as
    /// 0), attributed to the flow's pid. A payload without processID falls
    /// back to the pid learned from this source's earlier description.
    private func ingest(source: UnsafeMutableRawPointer, reading: [String: Any]?) {
        guard let reading else { return }
        let pidValue = (reading["processID"] as? NSNumber)?.intValue ?? Int(perSourceLast[source]?.pid ?? 0)
        guard pidValue > 0 else { return }
        let pid = pid_t(pidValue)
        let rx = (reading["rxBytes"] as? NSNumber)?.uint64Value ?? 0
        let tx = (reading["txBytes"] as? NSNumber)?.uint64Value ?? 0
        let last = perSourceLast[source] ?? (pid: pid, rx: 0, tx: 0)
        var totals = totalsByPID[pid] ?? Totals()
        if rx > last.rx { totals.bytesIn &+= rx - last.rx }
        if tx > last.tx { totals.bytesOut &+= tx - last.tx }
        totalsByPID[pid] = totals
        perSourceLast[source] = (pid: pid, rx: max(rx, last.rx), tx: max(tx, last.tx))
    }
}
