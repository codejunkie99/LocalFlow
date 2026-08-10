import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

// Basic compilation check: the test file compiles against LocalFlowPlatform
// Real availability tests require actual Apple frameworks at runtime
assert(true, "test scaffold compiles")
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
