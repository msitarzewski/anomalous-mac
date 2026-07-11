import Foundation

/// Exports the local incident journal as CSV — a plain, portable copy the user
/// can keep or analyse elsewhere. Pure and deterministic (inject the formatter)
/// so it unit-tests without any app state. Local file only; nothing is sent.
public enum HistoryCSV {
    public static let header = [
        "process", "bundle_id", "kind", "type", "summary", "action",
        "safety_tier", "judged_by_model", "detected_at", "resolved_at",
        "active_seconds", "resolution"
    ]

    public static func string(
        from entries: [JournalEntry],
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> String {
        var rows = [header.joined(separator: ",")]
        for e in entries {
            let fields = [
                e.processName,
                e.bundleID ?? "",
                e.kind,
                Anomaly.Kind(rawValue: e.kind)?.plainLabel ?? e.kind,
                e.summary,
                e.action,
                String(e.safetyTier),
                e.judgedByModel ? "true" : "false",
                formatter.string(from: e.detectedAt),
                formatter.string(from: e.resolvedAt),
                String(Int(e.duration.rounded())),
                e.resolution.rawValue,
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        // Trailing newline so appending/round-tripping stays clean.
        return rows.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 field escaping: quote when the value contains a comma, quote,
    /// CR or LF, and double any embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
