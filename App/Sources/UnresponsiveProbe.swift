import Foundation

/// Answers a single question — "is this GUI app's event loop wedged?" — for the
/// hung-app detector (`Anomaly.Kind.appHung`). A "Not Responding" app is the
/// INVERSE of every resource rule: its main thread is blocked, so CPU sits near
/// zero and RSS stays flat and none of the over-use rules in `DetectionRules`
/// ever fire. The only reliable signal is the window-server's own liveness flag
/// — the very bit macOS uses to decide when to paint the spinning beachball and
/// dim the window with "Application Not Responding".
///
/// ⚠️ PRIVATE API — read before touching. `CGSMainConnectionID()` and
/// `CGSEventIsAppUnresponsive(_:_:)` are CoreGraphics **SPI**: unexported from
/// the public headers, undocumented, and NOT part of any stable contract. Apple
/// can rename, re-signature, or delete them in any macOS update (including a dot
/// release). Two consequences we design around:
///
///  1. We resolve the symbols **dynamically with `dlsym`** rather than linking
///     against them. If a future OS drops or renames either symbol,
///     `isUnresponsive(pid:)` simply returns `false` (we never flag) instead of
///     the whole app failing to launch on a missing symbol. Fail safe, fail
///     quiet.
///  2. This is a **Developer-ID / direct-distribution** capability only. Private
///     API use is grounds for Mac App Store rejection — never ship this file in
///     an App Store build.
///
/// Verified against the macOS 26 SDK signature `CGSEventIsAppUnresponsive(cid,
/// pid)`. Because it cannot be exercised by `swift build`/`swift test` (there is
/// no window-server connection in a test process, and the symbols are SPI), the
/// integrator MUST verify this against a real app build. If a future SDK returns
/// the old Carbon `Boolean` (`unsigned char`) instead of C99 `bool`, switch the
/// return type of `EventIsAppUnresponsiveFn` to `DarwinBoolean` and read
/// `.boolValue`. If it reverts to the legacy `ProcessSerialNumber *` argument,
/// swap the second parameter accordingly.
///
/// Lives in the App target (not `AnomalousCore`) on purpose: it depends on the
/// GUI window-server connection, which only exists inside a running `.app`. The
/// core stays pure and fully unit-testable.
///
/// ── Integration contract for `AppState` ────────────────────────────────────
/// A hung app has no metric history to accumulate, so detection is driven by a
/// boolean sampled each tick, not by `ProcessSample`s. In `AppState.tick()`:
///
///  1. For each sampled process that is a GUI app (`identity.bundleID != nil`),
///     call `UnresponsiveProbe.isUnresponsive(pid: identity.pid)`.
///  2. Track a **consecutive-unresponsive duration per identity**. Keep a
///     `[ProcessIdentity: Date] unresponsiveSince` map: set it to `.now` on the
///     first tick a GUI app reports unresponsive; clear the entry (back to
///     responsive → not hung) the moment it reports responsive again; and drop
///     it when the process exits (reuse the existing miss-count eviction).
///  3. Each tick, compute `unresponsiveSeconds = now - unresponsiveSince[id]`
///     and call
///     `DetectionRules.hungAppAnomaly(identity: id,
///                                    unresponsiveSeconds: unresponsiveSeconds,
///                                    threshold: thresholds.appHungSeconds,   // default 25s
///                                    magnitudeCurve: [unresponsiveSeconds],  // or a per-tick curve
///                                    detectedAt: .now)`
///     Feed the returned `Anomaly?` into the SAME chain as `stillAnomalous(_:)`
///     (append to `detected`, `markFlagged`, `judge`) so it flows to the
///     deterministic `appHung` card exactly like the resource rules. Fire ONCE
///     per hang: `alreadyFlagged` already de-dupes; on recovery, clearing the
///     `unresponsiveSince` entry lets the standard auto-clear resolve the card.
enum UnresponsiveProbe {
    #if ANOMALOUS_HUNG_PROBE

    // C function-pointer shapes for the two SPI symbols.
    // `CGSConnectionID` is a typedef for `int` (Int32); the unresponsive check
    // returns C99 `bool`.
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias EventIsAppUnresponsiveFn = @convention(c) (Int32, pid_t) -> Bool

    // Resolve once, lazily. `RTLD_DEFAULT` searches every image already mapped
    // into the process — CoreGraphics is pulled in by AppKit — so there is no
    // need to `dlopen` a private framework path.
    private static let mainConnectionID: MainConnectionIDFn? = lookup("CGSMainConnectionID")
    private static let eventIsAppUnresponsive: EventIsAppUnresponsiveFn? = lookup("CGSEventIsAppUnresponsive")

    private static func lookup<T>(_ symbol: String) -> T? {
        // `RTLD_DEFAULT` is `((void *)-2)` on Darwin — searches every image
        // already mapped into the process (CoreGraphics is pulled in by AppKit).
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, symbol) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// True iff the window-server currently considers `pid`'s GUI app to be
    /// blocked ("Not Responding"). Returns `false` — and therefore never flags —
    /// when the private symbols are unavailable on this OS, when there is no GUI
    /// connection, or for any non-GUI pid.
    static func isUnresponsive(pid: pid_t) -> Bool {
        guard let mainConnectionID, let eventIsAppUnresponsive else { return false }
        let cid = mainConnectionID()
        guard cid != 0 else { return false }
        return eventIsAppUnresponsive(cid, pid)
    }

    #else

    /// DISABLED (v0.1.4): calling the SkyLight unresponsive SPI on a real macOS
    /// 26 build segfaults — `EXC_BAD_ACCESS` inside `SLSEventIsAppUnresponsive`,
    /// a wrong SPI signature/connection that can't be caught. The hung-app rule,
    /// card, and journal are all in place; only this live signal is off
    /// (fail-safe) until the SPI call is corrected and verified on-device.
    /// Re-enable the machinery above with `-D ANOMALOUS_HUNG_PROBE` once fixed.
    static func isUnresponsive(pid _: pid_t) -> Bool { false }

    #endif
}
