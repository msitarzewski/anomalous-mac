import SwiftUI
import AnomalousCore

/// "What has Anomalous caught" — the send-log made human. Reads the
/// byte-for-byte log the app writes; this is the user-facing half of the
/// two-ledger transparency mechanism (diffable against the server mirror).
struct HistoryView: View {
    let directory: URL
    @State private var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let flow: String
        let sentAt: Date
        let json: String
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Nothing sent yet",
                    systemImage: "tray",
                    description: Text("Signatures the app contributes will appear here, exactly as they were sent."))
            } else {
                List(entries) { entry in
                    DisclosureGroup {
                        Text(entry.json)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        HStack {
                            Text(entry.flow.capitalized).font(.headline)
                            Spacer()
                            Text(entry.sentAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle("History")
        .task { await load() }
    }

    private func load() async {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Entry] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payloadB64 = obj["payload"] as? String,
                  let payload = Data(base64Encoded: payloadB64),
                  let pretty = try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: payload), options: [.prettyPrinted, .sortedKeys])
            else { continue }
            let flow = obj["flow"] as? String ?? "signature"
            let sentAt = (obj["sentAt"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) } ?? .now
            loaded.append(Entry(flow: flow, sentAt: sentAt, json: String(decoding: pretty, as: UTF8.self)))
        }
        entries = loaded.sorted { $0.sentAt > $1.sentAt }
    }
}
