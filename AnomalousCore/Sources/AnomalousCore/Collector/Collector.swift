import Foundation
import Darwin

/// The dumb, cheap, always-on layer. Samples every process via libproc —
/// no `ps` parsing — on a ~1–2 minute cadence. MUST stay provably under
/// 0.5% CPU average (projectRules.md #9): the watchdog that spins fans is
/// a punchline, not a product.
public actor Collector {
    public struct Configuration: Sendable {
        public var samplingInterval: TimeInterval
        public init(samplingInterval: TimeInterval = 90) {
            self.samplingInterval = samplingInterval
        }
    }

    private let configuration: Configuration
    private var identityCache: [pid_t: ProcessIdentity] = [:]

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// One sampling tick: every visible process, one ProcessSample each.
    public func sampleAll() -> [ProcessSample] {
        let now = Date()
        let nowAbs = mach_absolute_time()
        let pids = Self.allPIDs()
        let samples: [ProcessSample] = pids.compactMap { pid in
            guard let usage = Self.rusage(for: pid) else { return nil }
            let identity = identity(for: pid, startAbsTime: usage.startAbsTime)
            let uptime = usage.startAbsTime <= nowAbs
                ? Double(nowAbs - usage.startAbsTime) * Self.machTimebaseSecondsPerTick
                : 0
            return ProcessSample(
                identity: identity,
                timestamp: now,
                cpuTimeSeconds: usage.cpuTimeSeconds,
                residentBytes: usage.residentBytes,
                uptimeSeconds: uptime
            )
        }
        // Evict cache entries for pids gone this tick — mirrors history pruning.
        let livePIDs = Set(pids)
        identityCache = identityCache.filter { livePIDs.contains($0.key) }
        return samples
    }

    // MARK: - libproc

    static func allPIDs() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 16)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count) * Int32(MemoryLayout<pid_t>.stride))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    public struct Usage {
        public let cpuTimeSeconds: Double
        public let residentBytes: UInt64
        public let startAbsTime: UInt64
    }

    /// Public so the privileged helper (a separate target) can reuse the
    /// exact same read path — one implementation, root and non-root.
    public static func rusage(for pid: pid_t) -> Usage? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        let machSeconds = Self.machTimebaseSecondsPerTick
        return Usage(
            cpuTimeSeconds: Double(info.ri_user_time &+ info.ri_system_time) * machSeconds,
            residentBytes: info.ri_resident_size,
            startAbsTime: info.ri_proc_start_abstime
        )
    }

    public static let machTimebaseSecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    // MARK: - Identity

    private func identity(for pid: pid_t, startAbsTime: UInt64) -> ProcessIdentity {
        if let cached = identityCache[pid], cached.startAbsTime == startAbsTime {
            return cached
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = Self.string(fromCBuffer: nameBuffer)

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = Self.string(fromCBuffer: pathBuffer)

        // Resolve bundle metadata from the binary path — used for identity
        // and version-aware diagnosis. The PATH itself stays local, always.
        var bundleID: String?
        var appVersion: String?
        if !path.isEmpty, let bundle = Self.enclosingBundle(ofExecutablePath: path) {
            bundleID = bundle.bundleIdentifier
            appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        }

        // Owner: root or the user's account — a fact, not a guess.
        var bsdInfo = proc_bsdshortinfo()
        let bsdSize = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        let ownerIsRoot = bsdSize > 0 && bsdInfo.pbsi_uid == 0

        // Classify install source from the path, then discard the path
        // (it stays local; only the derived category survives on identity).
        let identity = ProcessIdentity(
            pid: pid,
            startAbsTime: startAbsTime,
            executableName: name.isEmpty ? (path as NSString).lastPathComponent : name,
            bundleID: bundleID,
            appVersion: appVersion,
            installSource: InstallSource.classify(path: path),
            ownerIsRoot: ownerIsRoot
        )
        identityCache[pid] = identity
        return identity
    }

    static func string(fromCBuffer buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    static func enclosingBundle(ofExecutablePath path: String) -> Bundle? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" || url.pathExtension == "xpc" || url.pathExtension == "appex" {
                return Bundle(url: url)
            }
        }
        return nil
    }
}
