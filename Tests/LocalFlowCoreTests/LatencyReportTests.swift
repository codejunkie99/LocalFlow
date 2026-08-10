import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func testMedianAndP95() {
    var report = LatencyReport()
    for i in 1...20 {
        report.samples.append(LatencySample(timestamp: .now, speechFinalizationMilliseconds: Double(i), rewriteMilliseconds: 0, pasteMilliseconds: 0, totalMilliseconds: Double(i), usedRawFallback: false))
    }
    assert(report.medianTotal == 10.5, "median of 1...20 is 10.5")
    assert(report.p95Total == 19.0, "p95 of 1...20 is 19")
}

func testEmptyReport() {
    let report = LatencyReport()
    assert(report.medianTotal == 0, "empty median is 0")
    assert(report.p95Total == 0, "empty p95 is 0")
}

testMedianAndP95()
testEmptyReport()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
