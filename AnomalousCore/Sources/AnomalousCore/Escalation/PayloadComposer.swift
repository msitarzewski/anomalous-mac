import Foundation

/// Composes the triage payload — the "referral letter." The defense is
/// structural: the payload is built ONLY from these allowlisted fields;
/// raw `ps` output, full paths, and command lines have no route into it
/// (command lines carry credentials — the founding incident's own fix
/// lived in `--sleep=0`).
public struct PayloadComposer: Sendable {
    public struct TriagePayload: Codable, Sendable {
        public let schemaVersion: String
        public let bundleID: String
        public let appVersion: String
        public let osVersion: String
        public let hardwareClass: String?
        /// The anomaly TYPE and install source are the condition dimensions
        /// the server caches on — so the same *kind* of problem on the same
        /// app/version is diagnosed once, globally, regardless of the specific
        /// magnitude/duration in this incident.
        public let anomalyType: String
        public let installSource: String
        public let summary: String
        public let metricCurves: MetricCurves

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case bundleID = "bundle_id"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case hardwareClass = "hardware_class"
            case anomalyType = "anomaly_type"
            case installSource = "install_source"
            case summary
            case metricCurves = "metric_curves"
        }
    }

    public struct MetricCurves: Codable, Sendable {
        public let cpuPercent: [Double]?
        public let rssMB: [Double]?
        public let gpuPercent: [Double]?
        public let wakeupsPerSecond: [Double]?
        public let diskBytesPerSecond: [Double]?
        /// The driving-metric curve for any kind not covered by a named field
        /// above (novel process, hung app, or a future rule). ALWAYS carries a
        /// curve when nothing else does, so `metric_curves` is never emitted as
        /// an empty object — an empty object fails the server's `required` rule
        /// and 422s the whole request (the GPU/wakeups/disk-anomaly bug).
        public let drivingCurve: [Double]?
        public let baselineCPUPercent: Double?
        public let baselineRSSMB: Double?

        enum CodingKeys: String, CodingKey {
            case cpuPercent = "cpu_percent"
            case rssMB = "rss_mb"
            case gpuPercent = "gpu_percent"
            case wakeupsPerSecond = "wakeups_per_second"
            case diskBytesPerSecond = "disk_bytes_per_second"
            case drivingCurve = "driving_metric_curve"
            case baselineCPUPercent = "baseline_cpu_percent"
            case baselineRSSMB = "baseline_rss_mb"
        }
    }

    public init() {}

    /// Builds the triage payload. Anonymization here is STRUCTURAL, not
    /// model-dependent: `summary` is assembled ONLY from already-safe
    /// fields (anomaly kind, executable base name, the baseline sentence) —
    /// there is no code path by which a file path, argument, username, or
    /// command line could reach it. This deterministic assembly is
    /// safe-by-construction and shippable as-is.
    ///
    /// A later enhancement lets the on-device model *rephrase* this summary
    /// into richer prose; because the model only ever sees these same safe
    /// fields, that upgrade cannot widen what leaves the machine. It is a
    /// quality improvement, not a privacy prerequisite.
    public func compose(anomaly: Anomaly, baselineSentence: String, osVersion: String, hardwareClass: String?) -> TriagePayload {
        TriagePayload(
            schemaVersion: "0.1.0",
            bundleID: anomaly.identity.bundleID ?? anomaly.identity.executableName,
            appVersion: anomaly.identity.appVersion ?? "unknown",
            osVersion: osVersion,
            hardwareClass: hardwareClass,
            anomalyType: anomaly.kind.rawValue,
            installSource: anomaly.identity.installSource.rawValue,
            summary: "\(anomaly.kind.rawValue) anomaly in \(anomaly.identity.executableName). Runs as \(anomaly.identity.ownerIsRoot ? "root" : "the user's account"); \(anomaly.identity.installSource.phrase). \(baselineSentence)\(Self.judgmentFacts(for: anomaly))",
            metricCurves: Self.curves(for: anomaly)
        )
    }

    /// Map the anomaly's single magnitude curve to the right named field for
    /// its kind, and ALWAYS fall back to `driving_metric_curve` when no named
    /// field applies — so `metric_curves` is guaranteed non-empty for every
    /// anomaly kind (an empty object 422s at the server's `required` rule).
    static func curves(for anomaly: Anomaly) -> MetricCurves {
        let curve = anomaly.magnitudeCurve
        let cpu = (anomaly.kind == .sustainedCPU || anomaly.kind == .cpuTimeRatio) ? curve : nil
        // memory.leak_footprint's curve is MB too — it rides rss_mb (footprint
        // is the honest successor).
        let rss = (anomaly.kind == .rssLeak || anomaly.kind == .rssCeiling || anomaly.kind == .memoryLeakFootprint) ? curve : nil
        let gpu = (anomaly.kind == .gpuSaturation) ? curve : nil
        let wakeups = (anomaly.kind == .energyWakeups) ? curve : nil
        let disk = (anomaly.kind == .diskThrash) ? curve : nil
        // Anything not covered above (novel process, hung app, future rules)
        // still carries its curve here, so the object is never empty.
        let driving = (cpu ?? rss ?? gpu ?? wakeups ?? disk) == nil ? curve : nil
        return MetricCurves(
            cpuPercent: cpu,
            rssMB: rss,
            gpuPercent: gpu,
            wakeupsPerSecond: wakeups,
            diskBytesPerSecond: disk,
            drivingCurve: driving,
            baselineCPUPercent: anomaly.kind == .sustainedCPU ? anomaly.baselineValue : nil,
            baselineRSSMB: anomaly.kind == .rssLeak || anomaly.kind == .memoryLeakFootprint ? anomaly.baselineValue : nil
        )
    }

    /// Phase 2 judgment facts, riding in the FREE-FORM summary (the phase
    /// spec's "confidence/contribution ride along in the existing payload,
    /// no schema change"). Carrying the wakeups/disk curves structurally
    /// would need new metric_curves fields = a schema_version bump — noted,
    /// deliberately not done here. Assembled only from already-safe fields,
    /// same structural-anonymity argument as the rest of the summary.
    static func judgmentFacts(for anomaly: Anomaly) -> String {
        var facts = ""
        if !anomaly.drivingMetric.isEmpty {
            facts += " Driving metric: \(anomaly.drivingMetric)"
            if let deviation = anomaly.baselineDeviation {
                facts += deviation.isFinite
                    ? String(format: ", %.1f MADs above its baseline", deviation)
                    : ", far above a flat baseline"
            }
            facts += "."
        }
        facts += String(format: " Confidence: %@ (%.2f).", anomaly.confidence.level.rawValue, anomaly.confidence.score)
        if !anomaly.alsoObserved.isEmpty {
            facts += " Also observed: \(anomaly.alsoObserved.joined(separator: "; "))."
        }
        if let context = anomaly.systemContext {
            facts += " \(context)"
        }
        return facts
    }
}
