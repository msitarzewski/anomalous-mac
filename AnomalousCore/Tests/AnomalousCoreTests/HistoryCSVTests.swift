import Testing
import Foundation
@testable import AnomalousCore

// HistoryCSV turns the journal into a portable, correctly-escaped CSV.

private func je(
    _ name: String,
    bundleID: String? = nil,
    kind: Anomaly.Kind = .sustainedCPU,
    summary: String = "ran hot",
    resolution: AnomalyResolution = .recovered
) -> JournalEntry {
    let d = Date(timeIntervalSince1970: 1_750_000_000)
    return JournalEntry(
        processName: name, bundleID: bundleID, kind: kind.rawValue,
        summary: summary, action: "Quit it.", safetyTier: 1, judgedByModel: true,
        detectedAt: d, resolvedAt: d.addingTimeInterval(120), resolution: resolution
    )
}

@Suite("history CSV export")
struct HistoryCSVTests {
    @Test("empty journal is just the header row")
    func emptyIsHeaderOnly() {
        let csv = HistoryCSV.string(from: [])
        #expect(csv == HistoryCSV.header.joined(separator: ",") + "\n")
    }

    @Test("a row carries plain type, tier, and ISO timestamps")
    func rowShape() {
        let csv = HistoryCSV.string(from: [je("appstoreagent")])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(String(lines[0]) == HistoryCSV.header.joined(separator: ","))
        let row = String(lines[1])
        #expect(row.contains("appstoreagent"))
        #expect(row.contains("sustained_cpu"))
        #expect(row.contains("High CPU"))            // plain label column
        #expect(row.contains("120"))                 // active_seconds
        #expect(row.contains("recovered"))
        #expect(row.contains("2025-06-15T"))         // ISO detected/resolved
    }

    @Test("fields with commas, quotes, and newlines are RFC-4180 escaped")
    func escaping() {
        #expect(HistoryCSV.escape("plain") == "plain")
        #expect(HistoryCSV.escape("a,b") == "\"a,b\"")
        #expect(HistoryCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.escape("line1\nline2") == "\"line1\nline2\"")
        // a summary with a comma must not break the column count
        let csv = HistoryCSV.string(from: [je("p", summary: "used 90% CPU, then calmed")])
        #expect(csv.contains("\"used 90% CPU, then calmed\""))
    }

    @Test("nil bundle id renders as an empty field, not the string nil")
    func nilBundle() {
        let csv = HistoryCSV.string(from: [je("dasd", bundleID: nil)])
        #expect(!csv.contains("nil"))
        #expect(csv.contains("dasd,,sustained_cpu"))
    }
}
