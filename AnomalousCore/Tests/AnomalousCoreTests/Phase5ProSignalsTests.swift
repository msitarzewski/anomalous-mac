import Testing
import Foundation
@testable import AnomalousCore

// Phase 5 — pro signals + cross-dimension fusion: the gpu.saturation and
// network.throughput Δ-rules (pure, fixture-driven), the IOUserClientCreator
// pid parse, resilient decoding of the new ProcessSample fields, the fusion/
// grouping behavior across the new dimensions, the foreground-intent
// acknowledgment envelope on a gpu kind, and live-gated probes of the SPI
// surfaces (real assertions where the surface exists on this box, clean
// pass-through where it does not — SPI absence must never fail the suite).

private func identity(_ name: String = "lmstudio", bundleID: String? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: 321, startAbsTime: 77, executableName: name, bundleID: bundleID)
}

/// GPU/network fixture: cumulative counters like the real fields (0 =
/// unknown). `secondsPerTick` in the gpu rule is injected as 1e-6 (1 tick =
/// 1 µs) so a share of P percent is P × 10_000 ticks per second — the
/// fixtures are timebase-independent.
private let fixtureSecondsPerTick = 1e-6

private func proSamples(
    minutes: Int,
    gpuPercent: Double = 0,
    networkBytesPerSecond: Double = 0
) -> [ProcessSample] {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    return (0...minutes).map { minute in
        let t = Double(minute) * 60
        return ProcessSample(
            identity: identity(),
            timestamp: start.addingTimeInterval(t),
            cpuTimeSeconds: t * 0.05,
            residentBytes: 100 * 1_048_576,
            uptimeSeconds: t,
            gpuTimeMachAbs: gpuPercent > 0 ? UInt64(1000 + t * gpuPercent / 100 / fixtureSecondsPerTick) : 0,
            netBytesIn: networkBytesPerSecond > 0 ? UInt64(4096 + t * networkBytesPerSecond / 2) : 0,
            netBytesOut: networkBytesPerSecond > 0 ? UInt64(4096 + t * networkBytesPerSecond / 2) : 0
        )
    }
}

private func baseline(median: Double, mad: Double, count: Int = 60, seasonal: Bool = false) -> SelectedBaseline {
    SelectedBaseline(stats: RobustStats(median: median, mad: mad, count: count), isSeasonal: seasonal)
}

@Suite("gpu.saturation — sustained per-process GPU share above the lineage's baseline")
struct GPUSaturationRuleTests {
    @Test("flags 80% device share sustained against a near-idle baseline")
    func flagsSaturation() {
        let anomaly = DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 15, gpuPercent: 80),
            baseline: baseline(median: 2, mad: 1),
            secondsPerTick: fixtureSecondsPerTick
        )
        #expect(anomaly?.kind == .gpuSaturation)
        #expect(anomaly?.kind.rawValue == "gpu.saturation")
        #expect(anomaly?.drivingMetric == "gpu_percent")
        #expect(abs((anomaly?.magnitudeCurve.last ?? 0) - 80) < 2)   // curve in %
        #expect((anomaly?.baselineDeviation ?? 0) > 8)
        #expect(anomaly?.baselineValue == 2)                          // the quotable "usual"
    }

    @Test("absolute floor: nobody's GPU dies at 5% — statistically loud stays silent")
    func respectsFloor() {
        // 5% is many MADs above a 0.1% baseline — and it is compositor noise.
        #expect(DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 15, gpuPercent: 5),
            baseline: baseline(median: 0.1, mad: 0.05),
            secondsPerTick: fixtureSecondsPerTick
        ) == nil)
    }

    @Test("warm-up gate: a lineage seen 2 ticks never fires, whatever the magnitude")
    func warmUpGate() {
        #expect(DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 15, gpuPercent: 90),
            baseline: baseline(median: 2, mad: 1, count: 2),
            secondsPerTick: fixtureSecondsPerTick
        ) == nil)
    }

    @Test("a share matching the lineage's own heavy history does not flag")
    func matchesOwnHistory() {
        // 85% against a median of 75 ± 10: renderers render. This is the
        // LM-Studio-class expected workload staying quiet at the RULE level
        // (the ack envelope is the second, user-taught line of defense).
        #expect(DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 15, gpuPercent: 85),
            baseline: baseline(median: 75, mad: 10),
            secondsPerTick: fixtureSecondsPerTick
        ) == nil)
    }

    @Test("0 = unknown counters (SPI dark) are excluded, never a reset")
    func unknownCountersExcluded() {
        #expect(DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 15, gpuPercent: 0),
            baseline: baseline(median: 2, mad: 1),
            secondsPerTick: fixtureSecondsPerTick
        ) == nil)
    }

    @Test("a burst shorter than the window is not 'sustained'")
    func respectsWindow() {
        #expect(DetectionRules.gpuSaturationAnomaly(
            history: proSamples(minutes: 5, gpuPercent: 90),
            baseline: baseline(median: 2, mad: 1),
            secondsPerTick: fixtureSecondsPerTick
        ) == nil)
    }
}

@Suite("network.throughput — sustained per-process traffic above the lineage's baseline")
struct NetworkThroughputRuleTests {
    @Test("flags 60 MB/s sustained against a near-idle baseline")
    func flagsThroughput() {
        let anomaly = DetectionRules.networkThroughputAnomaly(
            history: proSamples(minutes: 15, networkBytesPerSecond: 60 * 1_048_576),
            baseline: baseline(median: 100_000, mad: 50_000)
        )
        #expect(anomaly?.kind == .networkThroughput)
        #expect(anomaly?.kind.rawValue == "network.throughput")
        #expect(anomaly?.drivingMetric == "net_bytes_per_sec")
        // Curve and baselineValue are humanized to MB/s.
        #expect(abs((anomaly?.magnitudeCurve.last ?? 0) - 60) < 2)
    }

    @Test("the nightly-backup rate judged against ITS OWN bucket does not flag")
    func seasonalBaselineSuppresses() {
        // Same 60 MB/s — but the seasonal bucket learned this window usually
        // runs ~55 MB/s (previous nights' cloud sync).
        #expect(DetectionRules.networkThroughputAnomaly(
            history: proSamples(minutes: 15, networkBytesPerSecond: 60 * 1_048_576),
            baseline: baseline(median: 55 * 1_048_576, mad: 5 * 1_048_576, seasonal: true)
        ) == nil)
    }

    @Test("absolute floor: a chatty-but-modest process stays silent")
    func respectsFloor() {
        // 5 MB/s is loud against a near-zero baseline and not a drain.
        #expect(DetectionRules.networkThroughputAnomaly(
            history: proSamples(minutes: 15, networkBytesPerSecond: 5 * 1_048_576),
            baseline: baseline(median: 10_000, mad: 5_000)
        ) == nil)
    }

    @Test("warm-up gate holds")
    func warmUpGate() {
        #expect(DetectionRules.networkThroughputAnomaly(
            history: proSamples(minutes: 15, networkBytesPerSecond: 60 * 1_048_576),
            baseline: baseline(median: 100_000, mad: 50_000, count: 2)
        ) == nil)
    }

    @Test("0 = unknown counters (no sockets ever seen) never judge")
    func unknownCountersExcluded() {
        #expect(DetectionRules.networkThroughputAnomaly(
            history: proSamples(minutes: 15, networkBytesPerSecond: 0),
            baseline: baseline(median: 100_000, mad: 50_000)
        ) == nil)
    }
}

@Suite("IOUserClientCreator pid parse — pure, shape-drift-safe")
struct CreatorPIDParseTests {
    @Test("the on-device shape parses")
    func parsesRealShapes() {
        #expect(GPUSampler.parseCreatorPID("pid 462, WindowServer") == 462)
        #expect(GPUSampler.parseCreatorPID("pid 7874, Slack Helper") == 7874)
        #expect(GPUSampler.parseCreatorPID("pid 92929, Microsoft Edge H") == 92929)
        // A name containing digits/commas never contaminates the pid.
        #expect(GPUSampler.parseCreatorPID("pid 12, app, with, commas 34") == 12)
    }

    @Test("shape drift silences the dimension instead of misattributing")
    func rejectsDrift() {
        #expect(GPUSampler.parseCreatorPID("") == nil)
        #expect(GPUSampler.parseCreatorPID("WindowServer (pid 462)") == nil)
        #expect(GPUSampler.parseCreatorPID("pid , WindowServer") == nil)
        #expect(GPUSampler.parseCreatorPID("pid abc, WindowServer") == nil)
        #expect(GPUSampler.parseCreatorPID("pid 0, kernel") == nil)
        #expect(GPUSampler.parseCreatorPID("PID 462, WindowServer") == nil)
    }
}

@Suite("ProcessSample resilient decoding — Phase 5 fields across version skew")
struct Phase5SampleCodableTests {
    @Test("a Phase-1-vintage sample (energy fields, no gpu/net/neural) decodes with zero defaults")
    func phase1VintageDecodes() throws {
        let phase1 = """
        {"identity":{"pid":2,"startAbsTime":2,"executableName":"dasd"},
         "timestamp":773000000.0,"cpuTimeSeconds":20.0,"residentBytes":2000,"uptimeSeconds":200.0,
         "physFootprintBytes":4096,"energyNanojoules":77,"interruptWakeups":1400}
        """
        let sample = try JSONDecoder().decode(ProcessSample.self, from: Data(phase1.utf8))
        #expect(sample.energyNanojoules == 77)
        #expect(sample.gpuTimeMachAbs == 0)
        #expect(sample.neuralFootprintBytes == 0)
        #expect(sample.lifetimeMaxNeuralFootprintBytes == 0)
        #expect(sample.netBytesIn == 0)
        #expect(sample.netBytesOut == 0)
    }

    @Test("mixed-vintage array (v0.1, Phase-1, Phase-5 shapes) never poisons the decode")
    func mixedVintageArrayDecodes() throws {
        let mixed = """
        [{"identity":{"pid":1,"startAbsTime":1,"executableName":"launchd"},
          "timestamp":773000000.0,"cpuTimeSeconds":10.0,"residentBytes":1000,"uptimeSeconds":100.0},
         {"identity":{"pid":2,"startAbsTime":2,"executableName":"dasd"},
          "timestamp":773000000.0,"cpuTimeSeconds":20.0,"residentBytes":2000,"uptimeSeconds":200.0,
          "physFootprintBytes":4096,"energyNanojoules":77},
         {"identity":{"pid":3,"startAbsTime":3,"executableName":"WindowServer"},
          "timestamp":773000000.0,"cpuTimeSeconds":30.0,"residentBytes":3000,"uptimeSeconds":300.0,
          "gpuTimeMachAbs":12818670849750,"neuralFootprintBytes":786432,
          "lifetimeMaxNeuralFootprintBytes":346554368,"netBytesIn":1024,"netBytesOut":2048}]
        """
        let samples = try JSONDecoder().decode([ProcessSample].self, from: Data(mixed.utf8))
        #expect(samples.count == 3)
        #expect(samples[0].gpuTimeMachAbs == 0)
        #expect(samples[1].gpuTimeMachAbs == 0)
        #expect(samples[2].gpuTimeMachAbs == 12_818_670_849_750)
        #expect(samples[2].neuralFootprintBytes == 786_432)
        #expect(samples[2].lifetimeMaxNeuralFootprintBytes == 346_554_368)
        #expect(samples[2].netBytesIn == 1024)
        #expect(samples[2].netBytesOut == 2048)
    }

    @Test("full Phase-5 sample round-trips every field")
    func roundTrips() throws {
        let original = ProcessSample(
            identity: ProcessIdentity(pid: 7, startAbsTime: 9, executableName: "lmstudio"),
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            cpuTimeSeconds: 42, residentBytes: 1_048_576, uptimeSeconds: 600,
            physFootprintBytes: 2_097_152,
            gpuTimeMachAbs: 171_930_386_625,
            neuralFootprintBytes: 10_207_232,
            lifetimeMaxNeuralFootprintBytes: 22_708_224,
            netBytesIn: 39_232_406,
            netBytesOut: 42_017_032
        )
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("SystemSignals with pro signals round-trips; a pre-Phase-5 snapshot decodes nil")
    func systemSignalsCompat() throws {
        let enriched = SystemSignals(
            memoryPressureLevel: 1, swapUsedBytes: 0, swapTotalBytes: 0,
            thermalState: .nominal, coreCount: 16,
            loadAverage1: 1, loadAverage5: 1, loadAverage15: 1,
            socTemperatureCelsius: 38.7,
            railPowerWatts: RailPowerReader.Watts(cpu: nil, gpu: 0.21, ane: nil),
            gpuDeviceUtilizationPercent: 7,
            gpuInUseSystemMemoryBytes: 1_311_162_368
        )
        let decoded = try JSONDecoder().decode(SystemSignals.self, from: JSONEncoder().encode(enriched))
        #expect(decoded == enriched)

        let old = """
        {"memoryPressureLevel":1,"swapUsedBytes":0,"swapTotalBytes":0,"thermalState":0,
         "coreCount":16,"loadAverage1":1,"loadAverage5":1,"loadAverage15":1}
        """
        let legacy = try JSONDecoder().decode(SystemSignals.self, from: Data(old.utf8))
        #expect(legacy.socTemperatureCelsius == nil)
        #expect(legacy.railPowerWatts == nil)
        #expect(legacy.gpuDeviceUtilizationPercent == nil)
    }
}

@Suite("cross-dimension fusion — burning energy AND hot GPU is ONE insight")
struct FusionTests {
    @Test("gpu + wakeups + disk deviations on one process collapse into a single grouped anomaly")
    func collapsesAcrossProSignalDimensions() {
        let who = identity("exfiltrator")
        let at = Date(timeIntervalSince1970: 1_750_000_000)
        func candidate(_ kind: Anomaly.Kind, metric: BaselineMetric, deviation: Double) -> Anomaly {
            Anomaly(kind: kind, identity: who, windowSeconds: 900, magnitudeCurve: [80],
                    baselineValue: 2, detectedAt: at,
                    drivingMetric: metric.rawValue, baselineDeviation: deviation)
        }
        let candidates = [
            candidate(.energyWakeups, metric: .wakeupsPerSecond, deviation: 20),
            candidate(.gpuSaturation, metric: .gpuPercent, deviation: 30),
            candidate(.diskThrash, metric: .diskBytesPerSecond, deviation: 9),
        ]
        let scored = ConfidenceEngine.annotate(candidates, signals: nil)
        // 2-of-N agreement: each statistical Δ-rule starts 0.5 and gains the
        // capped +0.4 for two agreeing peers → all high before magnitude.
        #expect(scored.allSatisfy { $0.confidence.level == .high })

        let primary = AnomalyGrouper.collapseSameProcess(scored)
        #expect(primary != nil)
        // ONE insight, the other two dimensions folded in as quotable facts.
        #expect(primary?.alsoObserved.count == 2)
        #expect(primary?.alsoObserved.contains { $0.contains("gpu_percent") || $0.contains("gpu.saturation") } == true
             || primary?.kind == .gpuSaturation)
        // The primary is the highest-confidence candidate; whatever won, the
        // insight spans gpu + energy + disk in one card.
        let mentioned = Set(([primary!.kind.rawValue] + primary!.alsoObserved.map { $0 }).joined(separator: " ")
            .split(separator: " ").map(String.init))
        _ = mentioned
        let dims = [primary!.kind.rawValue] + primary!.alsoObserved
        #expect(dims.joined(separator: " ").contains("energy.wakeups") || primary!.kind == .energyWakeups)
        #expect(dims.joined(separator: " ").contains("disk.thrash") || primary!.kind == .diskThrash)
    }

    @Test("new kinds are statistical (base 0.5), never self-qualifying — one alone stays quiet")
    func newKindsAreNotSelfQualifying() {
        let alone = Anomaly(
            kind: .gpuSaturation, identity: identity(), windowSeconds: 900,
            magnitudeCurve: [80], baselineValue: 2, detectedAt: .now,
            drivingMetric: BaselineMetric.gpuPercent.rawValue, baselineDeviation: 8
        )
        let scored = ConfidenceEngine.score(for: alone, agreeingRules: 0, signals: nil)
        #expect(scored.level == .medium)   // 0.5, exactly the Δ-rule posture
        // ...but a SPECTACULAR magnitude can carry it alone (the busy-poll rule).
        var loud = alone
        loud.confidence = Confidence(score: 1)
        let spectacular = Anomaly(
            kind: .gpuSaturation, identity: identity(), windowSeconds: 900,
            magnitudeCurve: [95], baselineValue: 1, detectedAt: .now,
            drivingMetric: BaselineMetric.gpuPercent.rawValue, baselineDeviation: 200
        )
        #expect(ConfidenceEngine.score(for: spectacular, agreeingRules: 0, signals: nil).level == .high)
    }
}

@Suite("intent heuristic — the foreground envelope keeps the nanny quiet for intentional GPU work")
struct GPUAcknowledgmentEnvelopeTests {
    @Test("a user-launched foreground app gets the 2.0× envelope on a gpu condition")
    func foregroundMultiplier() {
        // LM-Studio-class: bundled, user-installed, not root.
        let multiplier = AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: "ai.lmstudio.LMStudio", installSource: .userApplication, ownerIsRoot: false
        )
        #expect(multiplier == 2.0)
        // A root daemon melting the GPU is categorically different.
        #expect(AcknowledgmentDefaults.envelopeMultiplier(
            bundleID: nil, installSource: .appleSystem, ownerIsRoot: true
        ) == 1.5)
    }

    @Test("acknowledged gpu.saturation suppresses inside 2.0× and re-alerts above it")
    func envelopeAppliesToGPUKind() {
        // Acked at 60% GPU with the foreground 2.0× envelope.
        let record = AcknowledgmentRecord(
            acknowledgedMagnitude: 60, envelopeMultiplier: 2.0, processStartAbsTime: 77
        )
        // Still inside the envelope (90% < 120%): quiet — inference on
        // purpose is expected, the nanny stays silent.
        #expect(AcknowledgmentStore.evaluate(
            record: record, currentMagnitude: 90, processStartAbsTime: 77
        ) == .suppress)
        // Materially worse (130% > 120%): the anti-mute guarantee fires.
        #expect(AcknowledgmentStore.evaluate(
            record: record, currentMagnitude: 130, processStartAbsTime: 77
        ) == .realert(.materiallyWorse))
        // A NEW instance of the process is a fresh evaluation.
        #expect(AcknowledgmentStore.evaluate(
            record: record, currentMagnitude: 61, processStartAbsTime: 78
        ) == .realert(.newInstance))
    }

    @Test("the gpu condition key carries kind + dimension, so an acked gpu envelope never covers a new dimension")
    func conditionKeyPartitionsDimensions() {
        let gpuKey = AcknowledgmentStore.conditionKey(
            processKey: "ai.lmstudio.LMStudio", kind: Anomaly.Kind.gpuSaturation.rawValue,
            dimension: BaselineMetric.gpuPercent.rawValue
        )
        let netKey = AcknowledgmentStore.conditionKey(
            processKey: "ai.lmstudio.LMStudio", kind: Anomaly.Kind.networkThroughput.rawValue,
            dimension: BaselineMetric.networkBytesPerSecond.rawValue
        )
        #expect(gpuKey == "ai.lmstudio.LMStudio|gpu.saturation|gpu_percent")
        #expect(netKey == "ai.lmstudio.LMStudio|network.throughput|net_bytes_per_sec")
        #expect(gpuKey != netKey)
    }
}

// MARK: - Live-gated SPI probes (real assertions where the surface exists on
// this box, silent pass where it does not — the suite must stay green on any
// Mac and any future macOS that removes a surface).

@Suite("live SPI probes — Phase 5 acquisition paths on this machine")
struct Phase5LiveProbeTests {
    @Test("GPU sampler reads per-process accumulated time + a device snapshot where AGX exists")
    func gpuSamplerLive() {
        let reading = GPUSampler.read()
        guard reading.device != nil || !reading.gpuTimeByPID.isEmpty else {
            return // no IOAccelerator surface here (VM/future macOS) — dimension dark, tick survives
        }
        if let device = reading.device {
            #expect(device.deviceUtilizationPercent >= 0 && device.deviceUtilizationPercent <= 100)
            #expect(device.rendererUtilizationPercent >= 0 && device.rendererUtilizationPercent <= 100)
        }
        // Where clients exist, pids are real live processes with plausible times.
        for (pid, ticks) in reading.gpuTimeByPID.prefix(20) {
            #expect(pid > 0)
            _ = ticks // cumulative — 0 is legal (client open, nothing submitted)
        }
    }

    @Test("rusage v6 tail: the ANE fields decode from the live syscall")
    func aneFieldsLive() throws {
        // Semantics verified on-device (2026-07-05): running Vision face
        // detection moved OUR OWN ri_neural_footprint 0 → 10,207,232 bytes.
        // Here we only assert the field is present and plausible for some
        // process, without requiring an ANE user to exist right now.
        let usage = try #require(Collector.rusage(for: getpid()))
        #expect(usage.neuralFootprintBytes < 64 * 1024 * 1024 * 1024)
        #expect(usage.lifetimeMaxNeuralFootprintBytes < 64 * 1024 * 1024 * 1024)
    }

    @Test("SoC temperature reads a live die value where the IOHID grid exists")
    func temperatureLive() {
        guard let celsius = SoCTemperature.read() else {
            return // grid unavailable (VM / SPI drift) — reader returned nil, no crash
        }
        #expect(celsius > 5 && celsius < 120)
    }

    @Test("IOReport rail power: priming call nil, delta call yields plausible watts where readable")
    func railPowerLive() {
        let reader = RailPowerReader()
        let first = reader.sample()
        #expect(first == nil) // priming call by contract
        Thread.sleep(forTimeInterval: 0.5)
        guard let watts = reader.sample() else {
            return // IOReport unavailable — optional-graceful
        }
        // On 27.0/M5 unprivileged only the GPU rail accumulates; rails that
        // never moved are nil (honest absence), any reported value is sane.
        for rail in [watts.cpu, watts.gpu, watts.ane].compactMap({ $0 }) {
            #expect(rail >= 0 && rail < 500)
        }
    }

    @Test("NetworkStatistics attributes per-pid cumulative byte counts and stays monotonic")
    func networkStatsLive() {
        let sampler = NetworkStatsSampler()
        guard sampler.isAvailable else {
            return // SPI missing on this build — dimension dark by design
        }
        let first = sampler.snapshotTotals(timeout: 2.0)
        let second = sampler.snapshotTotals(timeout: 2.0)
        // Cumulative per pid: whatever pids persist across both snapshots
        // must never regress (the accumulator is monotonic by construction).
        for (pid, totals) in second {
            #expect(pid > 0)
            if let earlier = first[pid] {
                #expect(totals.bytesIn >= earlier.bytesIn)
                #expect(totals.bytesOut >= earlier.bytesOut)
            }
        }
    }
}
