import Testing
@testable import AnomalousCore

/// The root helper's kill authorization is the shared `TerminationGuard.decide`
/// policy, so the exact code that guards a root SIGTERM is the code under test.
@Suite("termination guard — the root kill authorization policy")
struct TerminationGuardTests {
    private let start: UInt64 = 123_456_789

    @Test("a normal, non-protected process with a matching start time is allowed")
    func allowsLegitimateTarget() {
        #expect(TerminationGuard.decide(pid: 4321, expectedStartAbsTime: start,
                                        liveStartAbsTime: start, name: "mysqld") == .allowed)
    }

    @Test("pid <= 1 (kernel_task, launchd) is always protected, even with a matching start")
    func refusesPidLteOne() {
        #expect(TerminationGuard.decide(pid: 0, expectedStartAbsTime: start,
                                        liveStartAbsTime: start, name: "kernel_task") == .protectedProcess)
        #expect(TerminationGuard.decide(pid: 1, expectedStartAbsTime: start,
                                        liveStartAbsTime: start, name: "launchd") == .protectedProcess)
    }

    @Test("a gone process (no live start time) reports no-such-process, not a kill")
    func refusesMissingProcess() {
        #expect(TerminationGuard.decide(pid: 4321, expectedStartAbsTime: start,
                                        liveStartAbsTime: nil, name: "") == .noSuchProcess)
    }

    @Test("pid-reuse guard: a live start time different from the caller's is refused")
    func refusesRecycledPid() {
        #expect(TerminationGuard.decide(pid: 4321, expectedStartAbsTime: start,
                                        liveStartAbsTime: start &+ 1, name: "mysqld") == .identityChanged)
    }

    @Test("every protected critical/system process is refused, whatever the caller claims")
    func refusesEveryProtectedName() {
        for name in TerminationGuard.protectedNames {
            #expect(TerminationGuard.decide(pid: 4321, expectedStartAbsTime: start,
                                            liveStartAbsTime: start, name: name) == .protectedProcess,
                    "expected \(name) to be protected")
        }
    }

    @Test("the wire codes the app switches on are stable (0=ok,1=identity,2=gone,3=eperm,4=other,5=protected)")
    func wireCodesAreStable() {
        #expect(TerminationVerdict.allowed.rawValue == 0)
        #expect(TerminationVerdict.identityChanged.rawValue == 1)
        #expect(TerminationVerdict.noSuchProcess.rawValue == 2)
        #expect(TerminationVerdict.notPermitted.rawValue == 3)
        #expect(TerminationVerdict.unsupported.rawValue == 4)
        #expect(TerminationVerdict.protectedProcess.rawValue == 5)
    }
}
