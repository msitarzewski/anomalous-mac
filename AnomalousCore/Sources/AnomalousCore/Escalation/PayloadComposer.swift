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
        public let baselineCPUPercent: Double?
        public let baselineRSSMB: Double?

        enum CodingKeys: String, CodingKey {
            case cpuPercent = "cpu_percent"
            case rssMB = "rss_mb"
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
            summary: "\(anomaly.kind.rawValue) anomaly in \(anomaly.identity.executableName). Runs as \(anomaly.identity.ownerIsRoot ? "root" : "the user's account"); \(anomaly.identity.installSource.phrase). \(baselineSentence)",
            metricCurves: MetricCurves(
                cpuPercent: anomaly.kind == .sustainedCPU || anomaly.kind == .cpuTimeRatio ? anomaly.magnitudeCurve : nil,
                rssMB: anomaly.kind == .rssLeak || anomaly.kind == .rssCeiling ? anomaly.magnitudeCurve : nil,
                baselineCPUPercent: anomaly.kind == .sustainedCPU ? anomaly.baselineValue : nil,
                baselineRSSMB: anomaly.kind == .rssLeak ? anomaly.baselineValue : nil
            )
        )
    }
}
