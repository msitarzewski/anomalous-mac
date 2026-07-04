import Testing
import Foundation
@testable import AnomalousCore

@Suite("action layer — conservative by default")
struct ProcessActionTests {
    @Test("tier 3 always yields explain-only, whatever the kind")
    func tier3IsExplainOnly() {
        for kind in [Anomaly.Kind.cpuTimeRatio, .rssLeak, .sustainedCPU, .novelProcess] {
            #expect(ProcessAction.offered(tier: 3, kind: kind, isApp: true) == .explainOnly)
            #expect(ProcessAction.offered(tier: 2, kind: kind, isApp: true) == .explainOnly)
        }
    }

    @Test("tier 1 memory anomaly on an app offers Restart, not kill")
    func tier1LeakRestarts() {
        #expect(ProcessAction.offered(tier: 1, kind: .rssLeak, isApp: true) == .restartApp)
        #expect(ProcessAction.offered(tier: 1, kind: .rssCeiling, isApp: false) == .terminate)
    }

    @Test("tier 1 cpu anomaly offers terminate")
    func tier1CPUTerminates() {
        #expect(ProcessAction.offered(tier: 1, kind: .cpuTimeRatio, isApp: false) == .terminate)
    }

    @Test("destructive flag drives the confirmation requirement")
    func destructiveFlag() {
        #expect(ProcessAction.terminate.isDestructive)
        #expect(ProcessAction.restartApp.isDestructive)
        #expect(!ProcessAction.update.isDestructive)
        #expect(!ProcessAction.explainOnly.isDestructive)
    }

    @Test("terminating a nonexistent pid reports a typed error, never crashes")
    func terminateMissingPid() {
        // pid 2^31-1 will not exist → the live rusage read fails first.
        let identity = ProcessIdentity(pid: 2_147_483_600, startAbsTime: 1, executableName: "ghost")
        guard case .failure(let error) = ProcessActuator().terminate(identity: identity) else {
            Issue.record("expected a failure for a nonexistent pid"); return
        }
        #expect(error == .noSuchProcess)
    }

    @Test("a reused pid (start time mismatch) is refused, never killed")
    func pidReuseRefused() {
        // pid 1 (launchd) exists, but its real start time is not 999 — so a
        // flagged identity claiming pid 1 @ startAbsTime 999 must be refused,
        // NOT sent SIGTERM. This is the confident-wrong-kill guard.
        let staleIdentity = ProcessIdentity(pid: 1, startAbsTime: 999, executableName: "launchd")
        guard case .failure(let error) = ProcessActuator().terminate(identity: staleIdentity) else {
            Issue.record("expected refusal for a reused pid"); return
        }
        // Either identityChanged (pid 1 live, start times differ) or
        // noSuchProcess (rusage unreadable) — never a kill.
        #expect(error == .identityChanged || error == .noSuchProcess)
    }

    @Test("root daemons get a copy-paste sudo command, not a button")
    func manualCommand() {
        #expect(ProcessActuator().manualCommand(forExecutable: "dasd") == "sudo killall dasd")
    }
}

@Suite("kernel_task is a symptom, never a target")
struct ThermalCardTests {
    @Test("kernel_task judged as thermal symptom, tier 3, no kill")
    func thermalCard() async throws {
        let map = try KnowledgeMap.shipped()
        let engine = JudgmentEngine(knowledgeMap: map)
        let anomaly = Anomaly(
            kind: .sustainedCPU,
            identity: ProcessIdentity(pid: 0, startAbsTime: 1, executableName: "kernel_task"),
            windowSeconds: 1800, magnitudeCurve: [400], baselineValue: nil, detectedAt: .now
        )
        let outcome = await engine.judge(anomaly, baselineSentence: "n/a")
        guard case .mapOnlyCard(let card) = outcome else {
            Issue.record("expected map-only thermal card"); return
        }
        #expect(card.actionSafetyTier == 3)
        #expect(card.whatItIs.contains("kernel"))
        #expect(card.whyItsProbablyHot.lowercased().contains("hot"))
    }
}
