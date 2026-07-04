import Foundation

/// Composes the anonymous anomaly signature — the free tier's ONLY
/// transmission, conforming to protocol/anomaly-signature.schema.json.
/// Anonymity is structural: this type has no fields for user, path,
/// hostname, or command line, so nothing identifiable CAN be composed.
public struct AnomalySignaturePayload: Codable, Sendable {
    public struct Process: Codable, Sendable {
        public let kind: String
        public let executableName: String
        public let bundleID: String?
        public let appVersion: String?
        /// Derived category (homebrew/docker/…), safe to contribute — it's
        /// how the process was installed, never the path itself.
        public let installSource: String

        enum CodingKeys: String, CodingKey {
            case kind
            case executableName = "executable_name"
            case bundleID = "bundle_id"
            case appVersion = "app_version"
            case installSource = "install_source"
        }
    }

    public struct AnomalyBody: Codable, Sendable {
        public let type: String
        public let windowSeconds: Int
        public let magnitudeCurve: [Double]
        public let baselineValue: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case windowSeconds = "window_seconds"
            case magnitudeCurve = "magnitude_curve"
            case baselineValue = "baseline_value"
        }
    }

    public struct Environment: Codable, Sendable {
        public let osVersion: String
        public let hardwareClass: String

        enum CodingKeys: String, CodingKey {
            case osVersion = "os_version"
            case hardwareClass = "hardware_class"
        }
    }

    public let schemaVersion: String
    public let platform: String
    public let process: Process
    public let anomaly: AnomalyBody
    public let environment: Environment
    public let observedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case platform
        case process
        case anomaly
        case environment
        case observedAt = "observed_at"
    }
}

public enum SignatureComposer {
    /// Builds the schema-conformant signature for an anomaly.
    /// `observed_at` is truncated to the hour (schema privacy note:
    /// resists timing correlation).
    public static func compose(anomaly: Anomaly) -> AnomalySignaturePayload {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AnomalySignaturePayload(
            schemaVersion: "0.1.0",
            platform: "macos",
            process: .init(
                kind: anomaly.identity.bundleID == nil ? "system_daemon" : "app",
                executableName: anomaly.identity.executableName,
                bundleID: anomaly.identity.bundleID,
                appVersion: anomaly.identity.appVersion,
                installSource: anomaly.identity.installSource.rawValue
            ),
            anomaly: .init(
                type: anomaly.kind.rawValue,
                windowSeconds: Int(anomaly.windowSeconds),
                magnitudeCurve: anomaly.magnitudeCurve,
                baselineValue: anomaly.baselineValue
            ),
            environment: .init(
                osVersion: "\(os.majorVersion).\(os.minorVersion)",
                hardwareClass: Self.hardwareClass
            ),
            observedAt: Self.hourTruncatedISO8601(anomaly.detectedAt)
        )
    }

    public static func encode(_ payload: AnomalySignaturePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// Coarse device class from hw.model (e.g. "Mac16,5") — the server's
    /// k-anonymity gate buckets rare classes further.
    public static var hardwareClass: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self).lowercased()
    }

    static func hourTruncatedISO8601(_ date: Date) -> String {
        let truncated = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        return ISO8601DateFormatter().string(from: truncated)
    }
}
