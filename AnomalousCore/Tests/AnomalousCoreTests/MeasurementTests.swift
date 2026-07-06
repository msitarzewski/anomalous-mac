import Testing
import Foundation
@testable import AnomalousCore

// Phase 1 measurement expansion: the rusage V6 fields, resilient sample
// decoding across app/helper version skew, and the system-signals snapshot.

@Suite("ProcessSample resilient decoding — app vs stale-helper version skew")
struct ProcessSampleCodableTests {
    @Test("old-shape JSON (no V6 fields) decodes with zero defaults, no throw")
    func oldShapeDecodesWithDefaults() throws {
        // Exactly what a pre-Phase-1 helper emits: the original five fields
        // (identity itself already exercises its own resilient path — no
        // installSource/ownerIsRoot keys here either).
        let old = """
        {"identity":{"pid":123,"startAbsTime":42,"executableName":"dasd"},
         "timestamp":773000000.0,
         "cpuTimeSeconds":90000.0,
         "residentBytes":1073741824,
         "uptimeSeconds":147600.0}
        """
        let sample = try JSONDecoder().decode(ProcessSample.self, from: Data(old.utf8))
        #expect(sample.identity.executableName == "dasd")
        #expect(sample.cpuTimeSeconds == 90000)
        #expect(sample.residentBytes == 1_073_741_824)
        #expect(sample.physFootprintBytes == 0)        // 0 = unknown → RSS fallback
        #expect(sample.lifetimeMaxPhysFootprintBytes == 0)
        #expect(sample.diskBytesRead == 0)
        #expect(sample.diskBytesWritten == 0)
        #expect(sample.energyNanojoules == 0)
        #expect(sample.pCoreEnergyNanojoules == 0)
        #expect(sample.idleWakeups == 0)
        #expect(sample.interruptWakeups == 0)
        #expect(sample.instructions == 0)
        #expect(sample.cycles == 0)
        // Phase 5 fields degrade identically (0 = unknown).
        #expect(sample.gpuTimeMachAbs == 0)
        #expect(sample.neuralFootprintBytes == 0)
        #expect(sample.lifetimeMaxNeuralFootprintBytes == 0)
        #expect(sample.netBytesIn == 0)
        #expect(sample.netBytesOut == 0)
    }

    @Test("an old-shape sample inside an array never poisons the whole decode")
    func oldShapeInsideArrayDecodes() throws {
        // The real failure mode: one helper array, mixed vintages — a strict
        // decoder would throw and the app would silently lose the root tier.
        let mixed = """
        [{"identity":{"pid":1,"startAbsTime":1,"executableName":"launchd"},
          "timestamp":773000000.0,"cpuTimeSeconds":10.0,"residentBytes":1000,"uptimeSeconds":100.0},
         {"identity":{"pid":2,"startAbsTime":2,"executableName":"dasd"},
          "timestamp":773000000.0,"cpuTimeSeconds":20.0,"residentBytes":2000,"uptimeSeconds":200.0,
          "physFootprintBytes":4096,"energyNanojoules":77}]
        """
        let samples = try JSONDecoder().decode([ProcessSample].self, from: Data(mixed.utf8))
        #expect(samples.count == 2)
        #expect(samples[0].physFootprintBytes == 0)
        #expect(samples[1].physFootprintBytes == 4096)
        #expect(samples[1].energyNanojoules == 77)
    }

    @Test("new-shape sample round-trips every field")
    func newShapeRoundTrips() throws {
        let original = ProcessSample(
            identity: ProcessIdentity(pid: 7, startAbsTime: 9, executableName: "mysqld", installSource: .homebrew),
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            cpuTimeSeconds: 1234.5,
            residentBytes: 2_147_483_648,
            uptimeSeconds: 3600,
            physFootprintBytes: 3_221_225_472,
            lifetimeMaxPhysFootprintBytes: 4_294_967_296,
            diskBytesRead: 1_000_000,
            diskBytesWritten: 2_000_000,
            energyNanojoules: 55_000_000_000,
            pCoreEnergyNanojoules: 40_000_000_000,
            idleWakeups: 98765,
            interruptWakeups: 4321,
            instructions: 9_000_000_000_000,
            cycles: 3_000_000_000_000,
            gpuTimeMachAbs: 12_818_670_849_750,
            neuralFootprintBytes: 786_432,
            lifetimeMaxNeuralFootprintBytes: 346_554_368,
            netBytesIn: 39_232_406,
            netBytesOut: 42_017_032
        )
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

@Suite("rusage V6 read path — live values on this machine")
struct RusageV6Tests {
    @Test("our own process reports plausible V6 metrics")
    func selfProcessReadsV6Fields() throws {
        let usage = try #require(Collector.rusage(for: getpid()))
        // A test runner has burned CPU, mapped memory, and retired
        // instructions by the time this line runs — these can't be zero
        // if the V6 flavor actually filled the struct.
        #expect(usage.cpuTimeSeconds > 0)
        #expect(usage.physFootprintBytes > 0)
        // Empirically (macOS 27) the kernel updates the lifetime high-water
        // mark LAZILY — it can momentarily read a hair below the live
        // footprint, so `>=` is not a kernel guarantee. Assert presence and
        // same order of magnitude instead.
        #expect(usage.lifetimeMaxPhysFootprintBytes > 0)
        #expect(usage.lifetimeMaxPhysFootprintBytes > usage.physFootprintBytes / 2)
        #expect(usage.instructions > 0)
        #expect(usage.cycles > 0)
        // phys_footprint is the honest number: it should differ from (and on
        // a live process not dwarf) RSS — sanity-bound it, don't equate it.
        #expect(usage.physFootprintBytes < 64 * 1024 * 1024 * 1024)
    }
}

@Suite("system signals — one machine-wide snapshot per tick")
struct SystemSignalsTests {
    @Test("live read returns sane values on this machine")
    func liveReadIsSane() {
        let signals = SystemSignals.read()
        // Kernel pressure levels are 1 (normal), 2 (warning), 4 (critical);
        // 0 only if the sysctl itself was unreadable.
        #expect([0, 1, 2, 4].contains(signals.memoryPressureLevel))
        #expect(signals.swapUsedBytes <= signals.swapTotalBytes)
        #expect(signals.coreCount > 0)
        #expect(signals.loadAverage1 >= 0)
        #expect(signals.loadAverage5 >= 0)
        #expect(signals.loadAverage15 >= 0)
    }

    @Test("thermal mapping is pure and total")
    func thermalMapping() {
        #expect(SystemSignals.ThermalState(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(SystemSignals.ThermalState(ProcessInfo.ThermalState.fair) == .fair)
        #expect(SystemSignals.ThermalState(ProcessInfo.ThermalState.serious) == .serious)
        #expect(SystemSignals.ThermalState(ProcessInfo.ThermalState.critical) == .critical)
    }

    @Test("snapshot round-trips through Codable (Phase 2 persists these)")
    func codableRoundTrip() throws {
        let original = SystemSignals(
            memoryPressureLevel: 2,
            swapUsedBytes: 1_073_741_824,
            swapTotalBytes: 2_147_483_648,
            thermalState: .fair,
            coreCount: 16,
            loadAverage1: 3.5,
            loadAverage5: 2.25,
            loadAverage15: 1.0
        )
        let decoded = try JSONDecoder().decode(SystemSignals.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
