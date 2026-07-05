import Foundation

/// An anomaly the detection rules produced. Pure data — the judgment layer
/// decides what it means; the action layer decides what can be done.
public struct Anomaly: Sendable, Equatable {
    public enum Kind: String, Sendable {
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
    }

    public let kind: Kind
    public let identity: ProcessIdentity
    public let windowSeconds: TimeInterval
    /// Downsampled metric curve over the window (percent CPU or MB RSS).
    public let magnitudeCurve: [Double]
    public let baselineValue: Double?
    public let detectedAt: Date

    public init(kind: Kind, identity: ProcessIdentity, windowSeconds: TimeInterval, magnitudeCurve: [Double], baselineValue: Double?, detectedAt: Date) {
        self.kind = kind
        self.identity = identity
        self.windowSeconds = windowSeconds
        self.magnitudeCurve = magnitudeCurve
        self.baselineValue = baselineValue
        self.detectedAt = detectedAt
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
    /// Cumulative-time ratio: cputime/uptime that flags with minimum uptime.
    /// This alone would have flagged dasd on FIRST LAUNCH of the app —
    /// it catches pre-existing runaways. (Rule 2, the founding incident)
    public var cpuTimeRatio: Double = 0.5
    public var cpuTimeRatioMinimumUptime: TimeInterval = 6 * 60 * 60
    /// RSS leak: monotonic growth to this multiple over the window, above a floor.
    public var rssGrowthMultiple: Double = 2.0
    public var rssGrowthWindow: TimeInterval = 30 * 60
    public var rssFloorBytes: UInt64 = 512 * 1024 * 1024
    /// Absolute ceiling for non-allowlisted processes.
    public var rssCeilingBytes: UInt64 = 16 * 1024 * 1024 * 1024

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
            detectedAt: sample.timestamp
        )
    }

    /// Rule 1: sustained CPU over a window. `history` must be time-ordered
    /// samples of ONE process identity spanning at least the window.
    public static func sustainedCPUAnomaly(
        history: [ProcessSample],
        baseline: Double?,
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
            detectedAt: last.timestamp
        )
    }

    /// Rule 3: monotonic RSS growth ≥ multiple over the window, above a floor.
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
            detectedAt: last.timestamp
        )
    }

    /// Rule 4: absolute RSS ceiling.
    public static func rssCeilingAnomaly(
        sample: ProcessSample,
        thresholds: DetectionThresholds = .init()
    ) -> Anomaly? {
        guard sample.residentBytes >= thresholds.rssCeilingBytes else { return nil }
        return Anomaly(
            kind: .rssCeiling,
            identity: sample.identity,
            windowSeconds: 0,
            magnitudeCurve: [Double(sample.residentBytes) / 1_048_576],
            baselineValue: nil,
            detectedAt: sample.timestamp
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
            detectedAt: detectedAt
        )
    }

    static func downsample(_ values: [Double], to maxCount: Int) -> [Double] {
        guard values.count > maxCount, maxCount > 0 else { return values }
        let stride = Double(values.count) / Double(maxCount)
        return (0..<maxCount).map { values[Int(Double($0) * stride)] }
    }
}
