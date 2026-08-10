import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func runAllTests() async {
    let immediate = await DeadlineRace.first(deadline: .milliseconds(100)) {
        "ready"
    }
    assert(immediate == "ready", "returns an operation result before the deadline")

    let started = ContinuousClock.now
    let timedOut = await DeadlineRace.first(deadline: .milliseconds(20)) {
        try? await Task.sleep(for: .seconds(2))
        return "late"
    }
    let elapsed = started.duration(to: .now)
    assert(timedOut == nil, "returns nil when the deadline wins")
    assert(elapsed < .milliseconds(150), "does not wait for the slow operation after timeout")
}

await runAllTests()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
