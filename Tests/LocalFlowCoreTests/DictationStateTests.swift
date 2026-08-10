import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func testActivePhasesAreBusy() {
    assert(!DictationPhase.idle.isBusy, "idle should not be busy")
    assert(DictationPhase.listening.isBusy, "listening should be busy")
    assert(DictationPhase.finalizing.isBusy, "finalizing should be busy")
    assert(DictationPhase.rewriting.isBusy, "rewriting should be busy")
    assert(DictationPhase.pasting.isBusy, "pasting should be busy")
    assert(!DictationPhase.failed(.microphoneDenied).isBusy, "failed should not be busy")
}

testActivePhasesAreBusy()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
