import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func testVolatileIsReplacedAndFinalIsAppendedOnce() {
    var value = TranscriptAccumulator()
    value.accept("hello wor", isFinal: false)
    assert(value.displayText == "hello wor", "volatile display text")
    value.accept("hello world", isFinal: true)
    value.accept("next thought", isFinal: true)
    assert(value.finalText == "hello world next thought", "final text accumulated")
}

func testRewriteGuard() {
    assert(RewritePolicy.accepts(candidate: "Send the report today.", original: "send the report today"), "valid rewrite")
    assert(!RewritePolicy.accepts(candidate: "I cannot help with that.", original: "send the report"), "refusal rejected")
    assert(!RewritePolicy.accepts(candidate: "", original: "send the report"), "empty rejected")
}

testVolatileIsReplacedAndFinalIsAppendedOnce()
testRewriteGuard()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
