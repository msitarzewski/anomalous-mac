import Foundation

/// How a process's binary got onto the machine, inferred from its path.
/// The PATH stays local (it can contain a username); only this derived
/// category is safe to surface in a card or contribute in a signature.
/// It sharpens both identity ("installed via Homebrew") and remediation
/// (a Homebrew service is stopped with `brew services stop`, not `kill`).
public enum InstallSource: String, Sendable, Codable, Equatable {
    case appleSystem = "apple_system"
    case homebrew
    case macports
    case userApplication = "user_application"
    case docker
    case npm
    case python
    case other

    /// Classify from an absolute executable path. Order matters — the most
    /// specific/least ambiguous prefixes are checked first.
    public static func classify(path: String) -> InstallSource {
        guard !path.isEmpty else { return .other }

        // Apple-managed locations.
        for p in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(p) {
            return .appleSystem
        }

        // Homebrew: /opt/homebrew (Apple Silicon) or /usr/local/Cellar (Intel),
        // plus symlinked bin dirs.
        if path.hasPrefix("/opt/homebrew/") || path.contains("/homebrew/Cellar/")
            || path.contains("/usr/local/Cellar/") || path.hasPrefix("/usr/local/opt/") {
            return .homebrew
        }

        // MacPorts.
        if path.hasPrefix("/opt/local/") { return .macports }

        // Container / language ecosystems (check before the generic
        // /Applications and /usr/bin buckets).
        if path.contains("/Docker.app/") || path.contains("/.docker/") { return .docker }
        if path.contains("/node_modules/") { return .npm }
        if path.contains("/site-packages/") || path.contains("/.venv/")
            || path.contains("/virtualenvs/") || path.contains("/Python.framework/") {
            return .python
        }

        // Ordinary Mac apps.
        if path.contains("/Applications/") { return .userApplication }

        // /usr/bin can be Apple (SIP-protected) — treat as system.
        if path.hasPrefix("/usr/bin/") || path.hasPrefix("/bin/") { return .appleSystem }

        return .other
    }

    /// Human phrase for the diagnosis card / LLM grounding.
    public var phrase: String {
        switch self {
        case .appleSystem: return "part of macOS"
        case .homebrew: return "installed via Homebrew"
        case .macports: return "installed via MacPorts"
        case .userApplication: return "a regular Mac app"
        case .docker: return "running under Docker"
        case .npm: return "installed via npm"
        case .python: return "a Python package"
        case .other: return "of unknown origin"
        }
    }

    /// The correct way to manage this process's lifecycle, when the source
    /// implies one that's safer than a raw kill.
    public var lifecycleHint: String? {
        switch self {
        case .homebrew: return "If it's a Homebrew service, stop it with `brew services stop <formula>` rather than killing it."
        case .macports: return "If managed by MacPorts, use `sudo port unload <name>` rather than killing it."
        case .docker: return "Stop the specific container with `docker stop <name>` rather than quitting Docker."
        default: return nil
        }
    }
}
