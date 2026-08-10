import LocalFlowPlatform
import Foundation

@MainActor final class MockShortcutMonitor: ShortcutMonitoring, @unchecked Sendable {
    weak var delegate: (any ShortcutDelegate)?
    var startCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor final class Counter {
    var presses = 0
    var releases = 0
}

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

await MainActor.run {
    let monitor = MockShortcutMonitor()
    let counter = Counter()
    let session = ShortcutSession(
        monitor: monitor,
        onPress: { counter.presses += 1 },
        onRelease: { counter.releases += 1 }
    )

    session.start()
    assert(monitor.delegate != nil, "session retains its weakly-held delegate")
    monitor.delegate?.shortcutPressed()
    monitor.delegate?.shortcutReleased()
    assert(counter.presses == 1, "forwards shortcut press")
    assert(counter.releases == 1, "forwards shortcut release")

    session.start()
    assert(monitor.startCount == 1, "start is idempotent")
}

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
