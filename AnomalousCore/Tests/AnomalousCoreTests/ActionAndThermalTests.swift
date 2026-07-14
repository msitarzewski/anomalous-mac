import Testing
import Foundation
@testable import AnomalousCore

@Suite("action layer — conservative by default")
struct ProcessActionTests {
    @Test("tier 3 yields explain-only, whatever the kind")
    func tier3IsExplainOnly() {
        for kind in [Anomaly.Kind.cpuTimeRatio, .rssLeak, .sustainedCPU, .novelProcess] {
            #expect(ProcessAction.offered(tier: 3, kind: kind, isApp: true) == .explainOnly)
        }
    }

    @Test("tier 2 (caution) still offers the action — an app restarts, a helper quits")
    func tier2OffersAction() {
        // Regression guard: tier 2 was returning explainOnly, so a card whose own
        // verdict said "quit it and reopen" had NO button (the Messages wakeups case).
        #expect(ProcessAction.offered(tier: 2, kind: .rssLeak, isApp: true) == .restartApp)
        #expect(ProcessAction.offered(tier: 2, kind: .cpuTimeRatio, isApp: false) == .terminate)
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

    @Test("safe_action enum maps to the concrete action (force rides the terminate path)")
    func safeActionMapping() {
        #expect(ProcessAction.from(safeAction: "quit") == .terminate)
        #expect(ProcessAction.from(safeAction: "force_quit") == .terminate)
        #expect(ProcessAction.from(safeAction: "restart") == .restartApp)
        #expect(ProcessAction.from(safeAction: "update") == .update)
        #expect(ProcessAction.from(safeAction: "none") == .explainOnly)
        #expect(ProcessAction.from(safeAction: "QUIT") == .terminate)   // case-insensitive
        #expect(ProcessAction.from(safeAction: "banana") == nil)         // unknown → no opinion
        #expect(ProcessAction.from(safeAction: nil) == nil)
    }

    @Test("reconciled takes the LESS aggressive action — the LLM can only make it safer")
    func reconciledTakesSafer() {
        // LLM says something SAFER than the deterministic offer → LLM wins.
        #expect(ProcessAction.reconciled(llm: .explainOnly, deterministic: .terminate) == .explainOnly)
        #expect(ProcessAction.reconciled(llm: .update, deterministic: .terminate) == .update)
        #expect(ProcessAction.reconciled(llm: .restartApp, deterministic: .terminate) == .restartApp)
        // LLM says something MORE aggressive → deterministic offer stands (clamped).
        #expect(ProcessAction.reconciled(llm: .terminate, deterministic: .explainOnly) == .explainOnly)
        #expect(ProcessAction.reconciled(llm: .terminate, deterministic: .update) == .update)
        #expect(ProcessAction.reconciled(llm: .restartApp, deterministic: .update) == .update)
        // Equal → unchanged; nil → deterministic untouched.
        #expect(ProcessAction.reconciled(llm: .terminate, deterministic: .terminate) == .terminate)
        #expect(ProcessAction.reconciled(llm: nil, deterministic: .terminate) == .terminate)
        #expect(ProcessAction.reconciled(llm: nil, deterministic: .explainOnly) == .explainOnly)
    }

    @Test("end-to-end: a tier-1 terminate offer is downgraded by a 'none' safe_action")
    func reconciledEndToEnd() {
        let deterministic = ProcessAction.offered(tier: 1, kind: .cpuTimeRatio, isApp: false)
        #expect(deterministic == .terminate)
        let reconciled = ProcessAction.reconciled(
            llm: ProcessAction.from(safeAction: "none"),
            deterministic: deterministic
        )
        #expect(reconciled == .explainOnly)   // stateful/system process: never a kill
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
