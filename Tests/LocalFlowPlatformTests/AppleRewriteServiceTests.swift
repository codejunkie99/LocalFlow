import LocalFlowCore
import LocalFlowPlatform
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func testRewriteServiceCreation() {
    _ = AppleRewriteService()
    assert(true, "service created")
}

func testRewritePolicyPrompt() {
    let prompt = RewritePolicy.prompt(for: "um send the report today")
    assert(prompt.contains("um send the report today"), "prompt contains dictation")
    assert(prompt.contains("Rewrite"), "prompt has rewrite instruction")
}

testRewriteServiceCreation()
testRewritePolicyPrompt()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
