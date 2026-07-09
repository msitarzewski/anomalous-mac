import Foundation

/// An anomaly the detection rules produced. Pure data — the judgment layer
/// decides what it means; the action layer decides what can be done.
public struct Anomaly: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case sustainedCPU = "sustained_cpu"
        case cpuTimeRatio = "cputime_ratio"
        case rssLeak = "rss_leak"
        case rssCeiling = "rss_ceiling"
        case novelProcess = "novel_process"
        /// The INVERSE of the resource rules: a GUI app whose event loop is
        /// blocked — "Not Responding". ~0 CPU, flat memory, so none of the
        /// over-use rules fire. Detected via the window-server's own
        /// unresponsive flag (see UnresponsiveProbe), not from ProcessSamples.
        case appHung = "app_hung"
        // Phase 2 kinds use the namespaced vocabulary from birth — server
        // ingest already validates it (app/Rules/AnomalyType.php); the legacy
        // five above keep their historical rawValues.
        /// Sustained interrupt-wakeup rate far above the lineage's baseline —
        /// the founding busy-poll mechanism (mysqld --sleep=0), detected BY
        /// MECHANISM instead of by its faint CPU shadow.
        case energyWakeups = "energy.wakeups"
        /// Sustained disk throughput far above the lineage's baseline.
        case diskThrash = "disk.thrash"
        /// Monotonic phys_footprint growth — the rssLeak logic ported to the
        /// honest memory number (RSS measured ~3× overstated in Phase 1).
        case memoryLeakFootprint = "memory.leak_footprint"
        // Phase 5 pro-signal kinds — same namespaced vocabulary.
        /// Sustained per-process GPU share far above the lineage's baseline
        /// (IOKit AGX accumulatedGPUTime Δ-rate) — the dimension every
        /// App-Store tool can only render system-wide.
        case gpuSaturation = "gpu.saturation"
        /// Sustained per-process network throughput far above the lineage's
        /// baseline (NetworkStatistics per-flow counters, folded per pid).
        case networkThroughput = "network.throughput"
    }

    public let kind: Kind
    public let identity: ProcessIdentity
    public let windowSeconds: TimeInterval
    /// Downsampled metric curve over the window (percent CPU, MB memory,
    /// wakeups/s, or MB/s disk — the kind says which).
    public let magnitudeCurve: [Double]
    public let baselineValue: Double?
    public let detectedAt: Date
    /// Which metric drove the flag (BaselineMetric rawValue vocabulary, e.g.
    /// "wakeups_per_sec") — Phase 3's LLM quotes this fact, never invents it.
    public let drivingMetric: String
    /// How many consistency-scaled MADs the driving metric sat above its
    /// selected baseline (RobustMath.deviation). nil = no robust baseline
    /// existed (legacy absolute rules on a cold lineage).
    public let baselineDeviation: Double?
    /// The judgment layer's graded verdict — stamped by ConfidenceEngine
    /// after detection; defaults to certain-high so any path that skips
    /// scoring keeps the pre-Phase-2 surfacing behavior.
    public var confidence: Confidence
    /// Correlated observations grouped into this one insight (other
    /// dimensions of the same process, or causally-linked processes) — the
    /// card renders them as a single "also:" line.
    public var alsoObserved: [String]
    /// Machine-wide caveat at detection time (thermal/memory duress), for
    /// the card and triage — nil when the machine was calm.
    public var systemContext: String?

    public init(
        kind: Kind,
        identity: ProcessIdentity,
        windowSeconds: TimeInterval,
        magnitudeCurve: [Double],
        baselineValue: Double?,
        detectedAt: Date,
        drivingMetric: String = "",
        baselineDeviation: Double? = nil,
        confidence: Confidence = Confidence(score: 1),
        alsoObserved: [String] = [],
        systemContext: String? = nil
    ) {
        self.kind = kind
        self.identity = identity
        self.windowSeconds = windowSeconds
        self.magnitudeCurve = magnitudeCurve
        self.baselineValue = baselineValue
        self.detectedAt = detectedAt
        self.drivingMetric = drivingMetric
        self.baselineDeviation = baselineDeviation
        self.confidence = confidence
        self.alsoObserved = alsoObserved
        self.systemContext = systemContext
    }
}

/// Detection thresholds. Ship CONSERVATIVE (high thresholds, long windows)
/// and loosen with data — false-positive tuning is the make-or-break; an
/// app that cries wolf gets deleted in a day (seed.md build order).
/// A soft-allowlist and partner-manifest modes RAISE these numbers per
/// envelope; nothing ever exempts a process entirely.
public struct DetectionThresholds: Sendable {
    /// Sustained CPU: average percent over the window that flags. (Rule 1)
    public var sustainedCPUPercent: Double = 80
    public var sustainedCPUWindow: TimeInterval = 25 * 60
    /// Chronic CPU (Rule 1b): a process whose ROBUST TYPICAL CPU — the median
    /// of its instantaneous CPU over the reservoir window — sits at/above this
    /// floor has been hot the whole time we've watched it. This is the
    /// baseline-poisoning blind spot: a runaway that predates a clean baseline
    /// never SPIKES above the 80% live bar and never DEVIATES from its own
    /// (now-poisoned) baseline, so Rules 1 and the Δ-rules both miss it. The
    /// floor is absolute and lower than sustainedCPUPercent because ~50%+
    /// sustained for a background process is pathological even though it never
    /// hits 80% — and being absolute, a poisoned per-lineage baseline cannot
    /// suppress it. Ship conservative; the ack envelope silences a user's own
    /// known-heavy app ("normal for me").
    public var chronicCPUPercent: Double = 50
    /// Cumulative-time ratio: cputime/uptime that flags with minimum uptime.
    /// This alone would have flagged dasd on FIRST LAUNCH of the app —
    /// it catches pre-existing runaways. (Rule 2, the founding incident)
    public var cpuTimeRatio: Double = 0.5
    public var cpuTimeRatioMinimumUptime: TimeInterval = 6 * 60 * 60
    /// RESOLUTION threshold for the cputime_ratio rule. The ratio is CUMULATIVE
    /// and never recovers on its own (43h of burn stays 43h; diluting it below
    /// the ratio needs ~43h more idle uptime), so it makes a great detector but
    /// a terrible resolver — a once-hot-now-idle process (dasd back at ~0% CPU)
    /// would keep its card forever. A cputime_ratio card therefore stays up only
    /// while LIVE (instantaneous) CPU is at/above this; below it the acute
    /// episode is over and the card heals. Detection still uses the ratio above.
    public var cpuTimeRatioActivePercent: Double = 20
    /// RSS leak: monotonic growth to this multiple over the window, above a floor.
    public var rssGrowthMultiple: Double = 2.0
    public var rssGrowthWindow: TimeInterval = 30 * 60
    public var rssFloorBytes: UInt64 = 512 * 1024 * 1024
    /// Leak HEAL gate: a leak is ONGOING growth, not a one-time ramp that
    /// settled. Once memory plateaus, the old low sample lingers in-window so
    /// end ≥ 2× start stays true forever and the card never clears (a code
    /// editor that loaded a big project and stabilized at 3.5 GB kept nagging
    /// for an hour). Require the recent tail of the window to still be climbing
    /// past this multiple; a flat tail means "settled at a new plateau, not
    /// leaking" and the rule stops firing so the card auto-resolves.
    public var leakTailGrowthMultiple: Double = 1.05
    /// Absolute ceiling for non-allowlisted processes.
    public var rssCeilingBytes: UInt64 = 16 * 1024 * 1024 * 1024

    // Phase 2 — Δ-rate rules over the measurement dimensions. Every new
    // counter is cumulative-since-start, so rules judge Δ-over-window rates,
    // never absolute reads; 0 = unknown (stale helper / V4 fallback) and is
    // excluded, never treated as a reset.
    /// energy.wakeups: absolute floor for the sustained interrupt-wakeup
    /// rate. A 1ms busy-poll measured ~1,400/s; a healthy daemon idles well
    /// under ~10/s. The floor keeps "9 MADs above a 0.2/s baseline" noise
    /// out — nobody's battery dies at 80 wakeups/s.
    public var wakeupsFloorPerSecond: Double = 150
    public var wakeupsWindow: TimeInterval = 10 * 60
    /// Consistency-scaled MADs above the selected baseline that flags.
    public var wakeupsMADMultiplier: Double = 8
    /// energy.wakeups corroboration floor. A wake spike only drains the battery
    /// if the process is actually DOING something — an idle interactive app (an
    /// editor at ~0% CPU) can have an elevated coalesced wake rate that costs
    /// next to nothing, and a card claiming it "drains the battery" would be
    /// false. Require this much average CPU over the window. The founding
    /// busy-poll (mysqld --sleep=0) ran at >100% CPU — it passes; the idle
    /// editor does not.
    public var wakeupsMinimumCPUPercent: Double = 3
    /// disk.thrash: sustained Δ disk bytes/s way above the lineage's own
    /// baseline. The floor is deliberately high (sustained, not burst): a
    /// 40 MB/s average over 10 minutes is ~24 GB of I/O.
    public var diskFloorBytesPerSecond: Double = 40 * 1024 * 1024
    public var diskWindow: TimeInterval = 10 * 60
    public var diskMADMultiplier: Double = 8
    /// memory.leak_footprint growth floor — phys_footprint is the honest
    /// number (RSS measured ~3× overstated in Phase 1), so its floor sits
    /// below the RSS floor.
    public var footprintFloorBytes: UInt64 = 256 * 1024 * 1024
    /// gpu.saturation: absolute floor for the sustained per-process GPU
    /// share. "Nobody's GPU dies at 5%" — a compositor blip that is 20 MADs
    /// above a near-zero baseline is humanly silent; ~40% of the device
    /// sustained for 10 minutes is a workload. (Parallel command queues can
    /// legitimately push the Δ-share past 100% — the floor is deliberately
    /// well below that.)
    public var gpuFloorPercent: Double = 40
    public var gpuWindow: TimeInterval = 10 * 60
    public var gpuMADMultiplier: Double = 8
    /// network.throughput: sustained bytes/s (in + out) way above the
    /// lineage's own baseline. The floor is conservative on purpose —
    /// 25 MB/s averaged over 10 minutes is ~15 GB of traffic; the seasonal
    /// baseline is what keeps the nightly cloud backup quiet.
    public var networkFloorBytesPerSecond: Double = 25 * 1024 * 1024
    public var networkWindow: TimeInterval = 10 * 60
    public var networkMADMultiplier: Double = 8
    /// Warm-up gate: a Δ-baseline rule may not fire until the lineage has
    /// this many recorded baseline observations — never judge a process
    /// watched for two ticks, however loud it looks.
    public var warmUpObservations: Int = 3
    /// A seasonal bucket must hold this many observations before values are
    /// judged against it instead of the global baseline.
    public var seasonalMinimumObservations: Int = 5

    public init() {}
}

/// Pure functions over sample history — deliberately stateless and fully
/// unit-testable without a live system.
public enum DetectionRules {

    /// Rule 2: cputime/uptime ratio over the PROCESS's own uptime —
    /// works from a SINGLE sample, no history needed.
    public static func cpuTimeRatioAnomaly(
        sample: ProcessSample,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        let uptime = sample.uptimeSeconds
        guard uptime >= thresholds.cpuTimeRatioMinimumUptime, uptime > 0 else { return nil }
        let ratio = sample.cpuTimeSeconds / uptime
        guard ratio >= thresholds.cpuTimeRatio else { return nil }
        return Anomaly(
            kind: .cpuTimeRatio,
            identity: sample.identity,
            windowSeconds: uptime,
            magnitudeCurve: [ratio * 100],
            baselineValue: nil,
            detectedAt: sample.timestamp,
            drivingMetric: BaselineMetric.cpuPercent.rawValue
        )
    }

    /// Recent INSTANTANEOUS CPU% (Δcputime/Δwall) averaged over the last
    /// `recentTicks` intervals of a process's sample history. Returns nil with
    /// fewer than two samples. Unlike the cumulative cputime/uptime ratio, this
    /// reflects what the process is doing RIGHT NOW — the signal a card's
    /// *resolution* must use so a once-hot-now-idle process can heal even while
    /// its lifetime ratio stays high. (Used by AppState.stillActive.)
    public static func instantaneousCPUPercent(
        history: [ProcessSample],
        recentTicks: Int = 3
    ) -> Double? {
        guard history.count >= 2, recentTicks >= 1 else { return nil }
        let window = history.suffix(recentTicks + 1)
        let percents = zip(window, window.dropFirst()).compactMap { earlier, later -> Double? in
            let dt = later.timestamp.timeIntervalSince(earlier.timestamp)
            guard dt > 0 else { return nil }
            return (later.cpuTimeSeconds - earlier.cpuTimeSeconds) / dt * 100
        }
        guard !percents.isEmpty else { return nil }
        return percents.reduce(0, +) / Double(percents.count)
    }

    /// Rule 1: sustained CPU over a window. `history` must be time-ordered
    /// samples of ONE process identity spanning at least the window.
    /// `robust` (optional) annotates HOW abnormal the average is for this
    /// lineage — it never gates this rule (the absolute threshold shipped
    /// conservative and stands alone); it feeds the confidence magnitude and
    /// gives Phase 3 a quotable "N MADs above its usual" fact.
    public static func sustainedCPUAnomaly(
        history: [ProcessSample],
        baseline: Double?,
        robust: RobustStats? = nil,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let first = history.first, let last = history.last else { return nil }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= thresholds.sustainedCPUWindow else { return nil }

        let percentCurve = zip(history, history.dropFirst()).compactMap { earlier, later -> Double? in
            let dt = later.timestamp.timeIntervalSince(earlier.timestamp)
            guard dt > 0 else { return nil }
            return (later.cpuTimeSeconds - earlier.cpuTimeSeconds) / dt * 100
        }
        guard !percentCurve.isEmpty else { return nil }
        let average = percentCurve.reduce(0, +) / Double(percentCurve.count)
        guard average >= thresholds.sustainedCPUPercent else { return nil }

        return Anomaly(
            kind: .sustainedCPU,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(percentCurve, to: 120),
            baselineValue: baseline,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.cpuPercent.rawValue,
            baselineDeviation: robust.map { RobustMath.deviation(average, from: $0) }
        )
    }

    /// Rule 1b: CHRONIC CPU — the baseline-poisoning catch. Keys on the ROBUST
    /// MEDIAN of the lineage's instantaneous CPU over the reservoir window: if a
    /// process's *typical* CPU is itself pathological (≥ chronicCPUPercent), the
    /// process has been a runaway since before a healthy baseline could form.
    /// That is exactly the case Rule 1 (needs an 80% live spike) and the Δ-rules
    /// (need deviation from a baseline the runaway has already poisoned) both
    /// miss. Absolute and baseline-independent — the poisoned baseline is the
    /// signal, not the excuse. The median (not the mean) keeps a single idle dip
    /// or spike from moving the verdict. `robust` is only non-nil once the
    /// reservoir has enough observations, so this can't fire on a cold process.
    public static func chronicCPUAnomaly(
        robust: RobustStats?,
        sample: ProcessSample,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let robust, robust.median >= thresholds.chronicCPUPercent else { return nil }
        return Anomaly(
            kind: .sustainedCPU,
            identity: sample.identity,
            windowSeconds: thresholds.sustainedCPUWindow,
            magnitudeCurve: [robust.median],
            baselineValue: robust.median,
            detectedAt: sample.timestamp,
            drivingMetric: BaselineMetric.cpuPercent.rawValue
        )
    }

    /// The honest memory reading: phys_footprint (Activity Monitor's Memory
    /// column, the number the kernel actually kills on) when known, RSS
    /// otherwise — 0 means UNKNOWN (stale helper / V4 fallback), never "no
    /// memory". Every memory rule keys on this.
    static func primaryMemoryBytes(_ sample: ProcessSample) -> UInt64 {
        sample.physFootprintBytes != 0 ? sample.physFootprintBytes : sample.residentBytes
    }

    /// Rule 3 (legacy): monotonic RSS growth ≥ multiple over the window,
    /// above a floor. Superseded in the live rule chain by
    /// `footprintLeakAnomaly` (which prefers phys_footprint and falls back
    /// to RSS itself); kept as a pure function because the `rss_leak` kind
    /// persists in journals/flags written by earlier versions and this
    /// documents exactly what those verdicts meant.
    public static func rssLeakAnomaly(
        history: [ProcessSample],
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let first = history.first, let last = history.last else { return nil }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= thresholds.rssGrowthWindow,
              first.residentBytes >= thresholds.rssFloorBytes,
              last.residentBytes >= UInt64(Double(first.residentBytes) * thresholds.rssGrowthMultiple)
        else { return nil }

        // Monotonic-ish: tolerate small dips (GC jitter), reject sawtooths.
        var peak: UInt64 = 0
        for sample in history {
            if sample.residentBytes < UInt64(Double(peak) * 0.9) { return nil }
            peak = max(peak, sample.residentBytes)
        }

        return Anomaly(
            kind: .rssLeak,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(history.map { Double($0.residentBytes) / 1_048_576 }, to: 120),
            baselineValue: Double(first.residentBytes) / 1_048_576,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.memoryMB.rawValue
        )
    }

    /// Rule 7 (memory.leak_footprint): the rssLeak logic ported to
    /// phys_footprint — monotonic growth ≥ multiple over the window, above a
    /// floor. Footprint is the honest number, so its floor sits lower
    /// (footprintFloorBytes vs rssFloorBytes). Mixed-vintage histories (any
    /// sample missing footprint — a stale helper mid-window) fall back to a
    /// pure RSS curve with the RSS floor: splicing the two units into one
    /// monotonic test would manufacture fake jumps at the seam.
    /// `baseline` (optional) annotates deviation for confidence/Phase 3; it
    /// never gates — this is the proven leak detector, the cold-start
    /// fast-path that must keep working during robust-baseline warm-up.
    public static func footprintLeakAnomaly(
        history: [ProcessSample],
        baseline: SelectedBaseline? = nil,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let first = history.first, let last = history.last else { return nil }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= thresholds.rssGrowthWindow else { return nil }

        let footprintKnown = history.allSatisfy { $0.physFootprintBytes != 0 }
        let curve = footprintKnown ? history.map(\.physFootprintBytes) : history.map(\.residentBytes)
        let floor = footprintKnown ? thresholds.footprintFloorBytes : thresholds.rssFloorBytes
        guard let start = curve.first, let end = curve.last,
              start >= floor,
              end >= UInt64(Double(start) * thresholds.rssGrowthMultiple)
        else { return nil }

        // Monotonic-ish: tolerate small dips (GC jitter), reject sawtooths.
        var peak: UInt64 = 0
        for value in curve {
            if value < UInt64(Double(peak) * 0.9) { return nil }
            peak = max(peak, value)
        }

        // Heal gate: only fire while the leak is STILL growing. Compare the
        // recent tail (≈ the final third of the window, always at least the last
        // two samples apart) to its start; a flat tail means the process settled
        // at a plateau — a one-time ramp, not an ongoing leak — so stop firing
        // and let the card auto-resolve instead of pinning a stable-but-large
        // process on screen indefinitely.
        if curve.count >= 3 {
            let tailIndex = min(curve.count - 2, (curve.count * 2) / 3)
            let tailStart = curve[tailIndex]
            if end < UInt64(Double(tailStart) * thresholds.leakTailGrowthMultiple) { return nil }
        }

        let megabytes = curve.map { Double($0) / 1_048_576 }
        return Anomaly(
            kind: .memoryLeakFootprint,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(megabytes, to: 120),
            baselineValue: Double(start) / 1_048_576,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.memoryMB.rawValue,
            baselineDeviation: baseline.map { RobustMath.deviation(megabytes.last ?? 0, from: $0.stats) }
        )
    }

    /// Rule 4: absolute memory ceiling — judged on the primary memory number
    /// (phys_footprint when known, RSS fallback). Kind keeps its legacy
    /// rawValue; only the input got more honest.
    public static func rssCeilingAnomaly(
        sample: ProcessSample,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        let memory = primaryMemoryBytes(sample)
        guard memory >= thresholds.rssCeilingBytes else { return nil }
        return Anomaly(
            kind: .rssCeiling,
            identity: sample.identity,
            windowSeconds: 0,
            magnitudeCurve: [Double(memory) / 1_048_576],
            baselineValue: nil,
            detectedAt: sample.timestamp,
            drivingMetric: BaselineMetric.memoryMB.rawValue
        )
    }

    /// Rule 6 (the inverse rule): a GUI app that has been "Not Responding" for
    /// at least `threshold` seconds. A hung app is the opposite of a runaway —
    /// its event loop is blocked, so CPU sits near zero and memory stays flat
    /// and none of rules 1–4 ever fire. Unlike those rules there is no metric
    /// history here: liveness is a boolean the window-server reports, so the
    /// caller (AppState) tracks how long the app has been continuously
    /// unresponsive and passes that duration in.
    ///
    /// `unresponsiveSeconds` is the consecutive-unresponsive duration the caller
    /// has accumulated; `magnitudeCurve` is a caller-supplied liveness/duration
    /// curve for the card's sparkline (e.g. seconds-unresponsive per tick).
    public static func hungAppAnomaly(
        identity: ProcessIdentity,
        unresponsiveSeconds: TimeInterval,
        threshold: TimeInterval = 25,
        magnitudeCurve: [Double],
        detectedAt: Date
    ) -> Anomaly? {
        guard unresponsiveSeconds >= threshold else { return nil }
        return Anomaly(
            kind: .appHung,
            identity: identity,
            windowSeconds: unresponsiveSeconds,
            magnitudeCurve: downsample(magnitudeCurve, to: 120),
            baselineValue: nil,
            detectedAt: detectedAt,
            drivingMetric: "unresponsive_seconds"
        )
    }

    // MARK: - Phase 2 Δ-rate rules (cumulative counters → rate-over-window)

    /// Δ-rate curve for a CUMULATIVE counter: per-pair (later − earlier)/Δt.
    /// A 0 read means UNKNOWN (stale helper / V4 fallback) — excluded, never
    /// treated as a reset to zero; counter regressions (shouldn't happen
    /// within one identity, but never trust a kernel counter blindly) are
    /// dropped the same way. nil unless the KNOWN readings span `window` —
    /// a rate judged from a shorter stretch isn't "sustained".
    static func rateCurve(
        history: [ProcessSample],
        window: TimeInterval,
        counter: (ProcessSample) -> UInt64
    ) -> (rates: [Double], span: TimeInterval)? {
        let known = history.filter { counter($0) != 0 }
        guard let first = known.first, let last = known.last else { return nil }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= window else { return nil }
        let rates = zip(known, known.dropFirst()).compactMap { earlier, later -> Double? in
            let dt = later.timestamp.timeIntervalSince(earlier.timestamp)
            let delta = Double(counter(later)) - Double(counter(earlier))
            guard dt > 0, delta >= 0 else { return nil }
            return delta / dt
        }
        return rates.isEmpty ? nil : (rates, span)
    }

    /// Rule 8 (energy.wakeups): sustained interrupt-wakeup rate far above
    /// the lineage's own baseline — the founding busy-poll mechanism,
    /// detected BY MECHANISM (a 1ms poll loop measured ~1,400/s in
    /// interruptWakeups while barely registering on CPU%). Fires only when
    /// ALL hold:
    ///   • warm-up gate: the lineage's baseline holds ≥ warmUpObservations
    ///     (never judge a process seen twice, however loud it looks);
    ///   • the window-average rate clears the absolute floor (statistical
    ///     loudness over a near-zero baseline is humanly silent);
    ///   • the average sits ≥ wakeupsMADMultiplier consistency-scaled MADs
    ///     above the selected (seasonal-when-warm, else global) median.
    public static func wakeupsAnomaly(
        history: [ProcessSample],
        baseline: SelectedBaseline?,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let baseline, baseline.stats.count >= thresholds.warmUpObservations else { return nil }
        guard let (rates, span) = rateCurve(history: history, window: thresholds.wakeupsWindow, counter: { $0.interruptWakeups }),
              let last = history.last
        else { return nil }
        let average = rates.reduce(0, +) / Double(rates.count)
        guard average >= thresholds.wakeupsFloorPerSecond else { return nil }
        let deviation = RobustMath.deviation(average, from: baseline.stats)
        guard deviation >= thresholds.wakeupsMADMultiplier else { return nil }
        // Corroboration: a wake spike from an idle process (an editor at ~0%
        // CPU) is cheap coalesced noise, not a battery drain — don't cry wolf.
        // Average CPU over the window must clear the floor; a real busy-poll
        // does real work and passes.
        let cpuWindow = history.suffix(rates.count + 1)
        let cpuRates = zip(cpuWindow, cpuWindow.dropFirst()).compactMap { earlier, later -> Double? in
            let dt = later.timestamp.timeIntervalSince(earlier.timestamp)
            guard dt > 0 else { return nil }
            return (later.cpuTimeSeconds - earlier.cpuTimeSeconds) / dt * 100
        }
        let averageCPU = cpuRates.isEmpty ? 0 : cpuRates.reduce(0, +) / Double(cpuRates.count)
        guard averageCPU >= thresholds.wakeupsMinimumCPUPercent else { return nil }
        return Anomaly(
            kind: .energyWakeups,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(rates, to: 120),
            baselineValue: baseline.stats.median,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.wakeupsPerSecond.rawValue,
            baselineDeviation: deviation
        )
    }

    /// Rule 9 (disk.thrash): sustained disk throughput (read + write) far
    /// above the lineage's own baseline. Same gate structure as wakeups:
    /// warm-up, absolute floor, then MADs above the selected baseline — the
    /// seasonal selection is what keeps the nightly backup quiet (judged
    /// against previous nights, not against the idle afternoon).
    /// Curve and baselineValue are in MB/s (human units for the card);
    /// thresholds and the recorded baseline stay in bytes/s.
    public static func diskThrashAnomaly(
        history: [ProcessSample],
        baseline: SelectedBaseline?,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let baseline, baseline.stats.count >= thresholds.warmUpObservations else { return nil }
        guard let (rates, span) = rateCurve(history: history, window: thresholds.diskWindow, counter: { $0.diskBytesRead &+ $0.diskBytesWritten }),
              let last = history.last
        else { return nil }
        let average = rates.reduce(0, +) / Double(rates.count)
        guard average >= thresholds.diskFloorBytesPerSecond else { return nil }
        let deviation = RobustMath.deviation(average, from: baseline.stats)
        guard deviation >= thresholds.diskMADMultiplier else { return nil }
        return Anomaly(
            kind: .diskThrash,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(rates.map { $0 / 1_048_576 }, to: 120),
            baselineValue: baseline.stats.median / 1_048_576,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.diskBytesPerSecond.rawValue,
            baselineDeviation: deviation
        )
    }

    /// Rule 10 (gpu.saturation): sustained per-process GPU share far above
    /// the lineage's own baseline. `gpuTimeMachAbs` is cumulative GPU time in
    /// mach-absolute ticks, so the Δ-rate (ticks/s) × secondsPerTick × 100 is
    /// "percent of one GPU-second per wall-second" — the same unit the
    /// baseline records (tickObservations). Same gate structure as
    /// wakeups/disk: warm-up, absolute floor (nobody's GPU dies at 5% — the
    /// floor sits at a sustained real workload), then MADs above the selected
    /// seasonal-when-warm baseline. `secondsPerTick` is injectable so the
    /// fixture tests are timebase-independent.
    public static func gpuSaturationAnomaly(
        history: [ProcessSample],
        baseline: SelectedBaseline?,
        thresholds: DetectionThresholds = .init(),
        secondsPerTick: Double = Collector.machTimebaseSecondsPerTick
    ) -> Anomaly? {
        guard let baseline, baseline.stats.count >= thresholds.warmUpObservations else { return nil }
        guard let (rates, span) = rateCurve(history: history, window: thresholds.gpuWindow, counter: { $0.gpuTimeMachAbs }),
              let last = history.last
        else { return nil }
        let percents = rates.map { $0 * secondsPerTick * 100 }
        let average = percents.reduce(0, +) / Double(percents.count)
        guard average >= thresholds.gpuFloorPercent else { return nil }
        let deviation = RobustMath.deviation(average, from: baseline.stats)
        guard deviation >= thresholds.gpuMADMultiplier else { return nil }
        return Anomaly(
            kind: .gpuSaturation,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(percents, to: 120),
            baselineValue: baseline.stats.median,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.gpuPercent.rawValue,
            baselineDeviation: deviation
        )
    }

    /// Rule 11 (network.throughput): sustained network throughput (in + out)
    /// far above the lineage's own baseline. Mirrors disk.thrash exactly —
    /// warm-up, a deliberately high absolute floor (sustained transfer, not a
    /// burst), MADs above the selected baseline; the seasonal selection keeps
    /// the nightly cloud sync quiet. Curve and baselineValue humanized to
    /// MB/s; thresholds and the recorded baseline stay bytes/s.
    public static func networkThroughputAnomaly(
        history: [ProcessSample],
        baseline: SelectedBaseline?,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard let baseline, baseline.stats.count >= thresholds.warmUpObservations else { return nil }
        guard let (rates, span) = rateCurve(history: history, window: thresholds.networkWindow, counter: { $0.netBytesIn &+ $0.netBytesOut }),
              let last = history.last
        else { return nil }
        let average = rates.reduce(0, +) / Double(rates.count)
        guard average >= thresholds.networkFloorBytesPerSecond else { return nil }
        let deviation = RobustMath.deviation(average, from: baseline.stats)
        guard deviation >= thresholds.networkMADMultiplier else { return nil }
        return Anomaly(
            kind: .networkThroughput,
            identity: last.identity,
            windowSeconds: span,
            magnitudeCurve: downsample(rates.map { $0 / 1_048_576 }, to: 120),
            baselineValue: baseline.stats.median / 1_048_576,
            detectedAt: last.timestamp,
            drivingMetric: BaselineMetric.networkBytesPerSecond.rawValue,
            baselineDeviation: deviation
        )
    }

    static func downsample(_ values: [Double], to maxCount: Int) -> [Double] {
        guard values.count > maxCount, maxCount > 0 else { return values }
        let stride = Double(values.count) / Double(maxCount)
        return (0..<maxCount).map { values[Int(Double($0) * stride)] }
    }
}
