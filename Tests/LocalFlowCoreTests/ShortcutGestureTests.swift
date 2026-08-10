import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

var gesture = ShortcutGesture()
let start = ContinuousClock.now

assert(gesture.pressed(at: start) == .start, "first press starts listening")
assert(gesture.released(at: start.advanced(by: .milliseconds(100))) == .keepListening, "quick tap arms toggle mode")
assert(gesture.pressed(at: start.advanced(by: .seconds(1))) == .none, "second tap does not restart the recorder")
assert(gesture.released(at: start.advanced(by: .seconds(1.1))) == .stop, "second tap stops toggle mode")

var heldGesture = ShortcutGesture()
assert(heldGesture.pressed(at: start) == .start, "hold starts listening")
assert(heldGesture.released(at: start.advanced(by: .seconds(1))) == .stop, "hold release stops listening")

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
