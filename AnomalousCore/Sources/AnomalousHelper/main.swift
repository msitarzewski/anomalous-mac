import Foundation
import AnomalousCore
import Darwin

// ============================================================================
// Anomalous privileged helper — runs as root (installed via
// SMAppService.daemon). Samples ALL processes (root-owned included) and
// performs root-daemon terminations, both of which the unprivileged app
// cannot. Vends its work over an XPC Mach service; nothing else.
//
// Two modes:
//   (default)  XPC listener — the production path.
//   --probe    Standalone: sample once, print root-vs-user readability, exit.
//              Lets us prove root visibility works BEFORE code-signing is in
//              place: `sudo swift run AnomalousHelper --probe`.
// ============================================================================

if CommandLine.arguments.contains("--probe") {
    Probe.run()
} else {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
    listener.delegate = delegate
    listener.resume()
    // Root daemons run forever; the listener owns the run loop.
    RunLoop.main.run()
}

// MARK: - XPC service

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only our Team-ID-signed app may drive the root helper. An unsigned
        // or foreign-signed local process is rejected — the root
        // sampler/killer is not open to anything on the machine.
        // (Skipped only for the unsigned --probe/dev path via the env flag,
        // so local development still works before signing.)
        if ProcessInfo.processInfo.environment["ANOMALOUS_HELPER_ALLOW_UNSIGNED"] == nil {
            connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        }
        connection.exportedInterface = NSXPCInterface(with: AnomalousHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

final class HelperService: NSObject, AnomalousHelperProtocol {
    func sampleAll(withReply reply: @escaping (Data?) -> Void) {
        let samples = PrivilegedSampler.sampleAll()
        reply(try? JSONEncoder().encode(samples))
    }

    func terminate(pid: Int32, expectedStartAbsTime: UInt64, withReply reply: @escaping (Int32) -> Void) {
        reply(PrivilegedSampler.terminate(pid: pid, expectedStartAbsTime: expectedStartAbsTime))
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }
}

// MARK: - Probe (standalone verification)

enum Probe {
    static func run() {
        let uid = getuid()
        let samples = PrivilegedSampler.sampleAll()
        // Compare against what a non-root process could see: count how many
        // we read that are root-owned.
        var rootRead = 0, userRead = 0
        for s in samples {
            if PrivilegedSampler.owner(s.identity.pid) == 0 { rootRead += 1 } else { userRead += 1 }
        }
        print("AnomalousHelper --probe (running as uid \(uid))")
        print("sampled \(samples.count) processes: \(rootRead) root-owned, \(userRead) user-owned")
        let dasd = samples.first { $0.identity.executableName == "dasd" }
        if let dasd {
            let gb = Double(dasd.residentBytes) / 1_073_741_824
            print("✅ dasd IS readable — RSS \(String(format: "%.2f", gb)) GB (the founding process, now visible)")
        } else if uid == 0 {
            print("⚠️ dasd not in sample (may not be running), but root processes ARE readable")
        } else {
            print("❌ not running as root — re-run with: sudo swift run AnomalousHelper --probe")
        }
    }
}

// MARK: - Root sampling core

enum PrivilegedSampler {
    static func sampleAll() -> [ProcessSample] {
        let now = Date()
        let nowAbs = mach_absolute_time()
        return allPIDs().compactMap { pid in
            guard let usage = Collector.rusage(for: pid) else { return nil }
            let uptime = usage.startAbsTime <= nowAbs
                ? Double(nowAbs - usage.startAbsTime) * Collector.machTimebaseSecondsPerTick : 0
            return ProcessSample(
                identity: identity(pid: pid, startAbsTime: usage.startAbsTime),
                timestamp: now,
                cpuTimeSeconds: usage.cpuTimeSeconds,
                residentBytes: usage.residentBytes,
                uptimeSeconds: uptime
            )
        }
    }

    /// Root-authorized termination with the same pid-reuse guard the app
    /// enforces: re-read the live start time, refuse on mismatch.
    static func terminate(pid: Int32, expectedStartAbsTime: UInt64) -> Int32 {
        guard let live = Collector.rusage(for: pid) else { return 2 } // no such process
        guard live.startAbsTime == expectedStartAbsTime else { return 1 } // identity changed
        guard kill(pid, SIGTERM) == 0 else {
            switch errno { case EPERM: return 3; case ESRCH: return 2; default: return 4 }
        }
        return 0
    }

    static func owner(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let sz = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        return sz > 0 ? info.pbsi_uid : nil
    }

    private static func allPIDs() -> [pid_t] {
        let cap = proc_listallpids(nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) + 16)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count) * Int32(MemoryLayout<pid_t>.stride))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    private static func identity(pid: pid_t, startAbsTime: UInt64) -> ProcessIdentity {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = String(decoding: pathBuffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

        var bsdInfo = proc_bsdshortinfo()
        let bsdSize = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdshortinfo>.size))

        return ProcessIdentity(
            pid: pid, startAbsTime: startAbsTime,
            executableName: name.isEmpty ? (path as NSString).lastPathComponent : name,
            installSource: InstallSource.classify(path: path),
            ownerIsRoot: bsdSize > 0 && bsdInfo.pbsi_uid == 0
        )
    }
}
