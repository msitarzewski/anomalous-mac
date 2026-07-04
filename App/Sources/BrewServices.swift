import Foundation

/// Live Homebrew services integration. When a flagged process was installed
/// via Homebrew and corresponds to a managed service, the CORRECT remedy
/// isn't `kill` — it's `brew services stop <formula>` (reversible, clean).
/// This queries and controls those services directly, the way BrewBrowser's
/// Services tab does. User-level Homebrew services need no root, so the app
/// runs these itself.
struct BrewService: Sendable, Equatable {
    let name: String
    let status: String   // "started" (running), "stopped", "none", "error", …
    var isRunning: Bool { status == "started" }
}

enum BrewServices {
    /// brew isn't on a GUI app's PATH — find it at the known locations.
    static let brewPath: String? = {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    static var isAvailable: Bool { brewPath != nil }

    /// `brew services list --json`, parsed. Empty if brew is absent.
    static func list() async -> [BrewService] {
        guard let brew = brewPath,
              let data = await run(brew, ["services", "list", "--json"]),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.map { BrewService(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "none") }
    }

    /// Start / stop / restart a service. Returns true on a clean exit.
    @discardableResult
    static func control(_ action: String, service: String) async -> Bool {
        guard let brew = brewPath else { return false }
        return await run(brew, ["services", action, service]) != nil
    }

    /// Map a process's executable name to its Homebrew service, matched
    /// against the RUNNING services (handles versioned formulae like
    /// postgresql@16 / php@8.4, and daemon-vs-formula name differences).
    static func matchRunning(processExecutable exe: String, in services: [BrewService]) -> BrewService? {
        let running = services.filter(\.isRunning)
        let aliases = [
            "mysqld": "mysql", "mariadbd": "mariadb", "redis-server": "redis",
            "mongod": "mongodb", "postgres": "postgresql", "php-fpm": "php",
        ]
        let target = aliases[exe] ?? exe
        return running.first { $0.name == target }
            ?? running.first { $0.name.hasPrefix(target + "@") }
            ?? running.first { exe.hasPrefix($0.name) || $0.name.hasPrefix(target) }
    }

    // MARK: - Subprocess

    private static func run(_ launchPath: String, _ arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let out = try? pipe.fileHandleForReading.readToEnd()
                continuation.resume(returning: proc.terminationStatus == 0 ? (out ?? Data()) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
