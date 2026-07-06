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
        sampleTick().samples
    }

    /// The full tick read: per-process samples PLUS the device-level GPU
    /// snapshot the same IOKit pass produced (system context for
    /// SystemSignals — reading it separately would double the registry walk).
    public func sampleTick() -> (samples: [ProcessSample], gpuDevice: GPUSampler.DeviceSnapshot?) {
        let now = Date()
        let nowAbs = mach_absolute_time()
        let pids = Self.allPIDs()
        // Phase 5 side-channels, once per tick: GPU clients are FEW (~100
        // registry nodes — never a 900-pid scan) and the network snapshot is
        // one batched SPI query. Both fail to empty; a pid absent from a map
        // reads 0 (= unknown) on its sample.
        let gpu = GPUSampler.read()
        let network = NetworkStatsSampler.shared.snapshotTotals()
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
                uptimeSeconds: uptime,
                physFootprintBytes: usage.physFootprintBytes,
                lifetimeMaxPhysFootprintBytes: usage.lifetimeMaxPhysFootprintBytes,
                diskBytesRead: usage.diskBytesRead,
                diskBytesWritten: usage.diskBytesWritten,
                energyNanojoules: usage.energyNanojoules,
                pCoreEnergyNanojoules: usage.pCoreEnergyNanojoules,
                idleWakeups: usage.idleWakeups,
                interruptWakeups: usage.interruptWakeups,
                instructions: usage.instructions,
                cycles: usage.cycles,
                gpuTimeMachAbs: gpu.gpuTimeByPID[pid] ?? 0,
                neuralFootprintBytes: usage.neuralFootprintBytes,
                lifetimeMaxNeuralFootprintBytes: usage.lifetimeMaxNeuralFootprintBytes,
                netBytesIn: network[pid]?.bytesIn ?? 0,
                netBytesOut: network[pid]?.bytesOut ?? 0
            )
        }
        // Evict cache entries for pids gone this tick — mirrors history pruning.
        let livePIDs = Set(pids)
        identityCache = identityCache.filter { livePIDs.contains($0.key) }
        return (samples, gpu.device)
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
        /// phys_footprint — the honest memory number (Activity Monitor's
        /// Memory column); RSS above stays as the secondary.
        public let physFootprintBytes: UInt64
        /// Lifetime high-water phys_footprint.
        public let lifetimeMaxPhysFootprintBytes: UInt64
        /// Cumulative disk I/O since process start.
        public let diskBytesRead: UInt64
        public let diskBytesWritten: UInt64
        /// Cumulative energy since process start (all cores), nanojoules —
        /// the public analog of Activity Monitor's "Energy Impact".
        public let energyNanojoules: UInt64
        /// P-core share of the energy (P/E split).
        public let pCoreEnergyNanojoules: UInt64
        /// Package-idle / interrupt wakeups — the real battery-drain signal
        /// (a busy-polling process climbs here even at modest CPU%).
        public let idleWakeups: UInt64
        public let interruptWakeups: UInt64
        /// Retired instructions / CPU cycles — real IPC, distinguishes
        /// productive busy-work from a spin.
        public let instructions: UInt64
        public let cycles: UInt64
        /// Neural Engine memory footprint (live / lifetime max), bytes —
        /// the rusage v6 tail (`ri_neural_footprint`); per-process ANE
        /// attribution in the same syscall, no SPI. 0 on the V4 fallback.
        public let neuralFootprintBytes: UInt64
        public let lifetimeMaxNeuralFootprintBytes: UInt64
    }

    /// Public so the privileged helper (a separate target) can reuse the
    /// exact same read path — one implementation, root and non-root.
    ///
    /// The flavor is pinned to `RUSAGE_INFO_V6` (macOS 15+; our floor is 26)
    /// instead of `RUSAGE_INFO_CURRENT` so a future SDK bump can never
    /// silently change the struct/flavor pairing underneath us. Fail-safe: if
    /// the kernel ever rejects V6, retry with V4 into the same zeroed buffer —
    /// the V4 layout is a strict prefix of V6, so the V6-only fields
    /// (energy_nj, penergy_nj) simply stay 0, which reads as "unknown".
    public static func rusage(for pid: pid_t) -> Usage? {
        var info = rusage_info_v6() // zero-initialized: unfilled fields read 0
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                var status = proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
                if status != 0 {
                    status = proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
                return status
            }
        }
        guard result == 0 else { return nil }
        let machSeconds = Self.machTimebaseSecondsPerTick
        return Usage(
            cpuTimeSeconds: Double(info.ri_user_time &+ info.ri_system_time) * machSeconds,
            residentBytes: info.ri_resident_size,
            startAbsTime: info.ri_proc_start_abstime,
            physFootprintBytes: info.ri_phys_footprint,
            lifetimeMaxPhysFootprintBytes: info.ri_lifetime_max_phys_footprint,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten,
            energyNanojoules: info.ri_energy_nj,
            pCoreEnergyNanojoules: info.ri_penergy_nj,
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            instructions: info.ri_instructions,
            cycles: info.ri_cycles,
            neuralFootprintBytes: info.ri_neural_footprint,
            lifetimeMaxNeuralFootprintBytes: info.ri_lifetime_max_neural_footprint
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
