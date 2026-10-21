import Darwin
import Testing
@testable import UnibrowCore

@Suite("Process ancestry")
struct ProcessAncestryTests {
    @Test("Parent of this process is found")
    func parentOfSelf() {
        #expect(ProcessAncestry.parentPID(of: getpid()) == getppid())
    }

    @Test("Root-owned processes are walked through (launchd's parent is 0)")
    func rootOwnedProcess() {
        // PID 1 (launchd) is owned by root; proc_pidinfo would refuse it.
        #expect(ProcessAncestry.parentPID(of: 1) == 0)
    }

    @Test("The chain starts at the process itself and goes up")
    func chain() {
        let chain = ProcessAncestry.candidates(of: getpid())
        #expect(chain.first == getpid())
        #expect(chain.dropFirst().first == getppid())
    }

    @Test("A process that does not exist has no parent")
    func missingProcess() {
        #expect(ProcessAncestry.parentPID(of: 999_999) == nil)
    }
}
