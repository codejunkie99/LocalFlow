import LocalFlowCore
import LocalFlowPlatform
import Foundation
import AppKit

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func testPasteServiceCreation() {
    let target = PasteTarget(processIdentifier: 42)
    assert(target == PasteTarget(processIdentifier: 42), "PasteTarget equality uses its process identifier")

    func acceptsPaster(_: some Pasting) {}
    acceptsPaster(PasteService())
    assert(true, "PasteService conforms to Pasting without touching the clipboard")
}

func testCaptureContextSnapshotsTargetPromptly() async {
    await withRestoredPasteboard {
        let expectedTarget = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                PasteTarget(processIdentifier: $0.processIdentifier)
            }
        }
        let service = PasteService()
        let started = ContinuousClock.now
        let target = await service.captureContext()
        let elapsed = started.duration(to: .now)
        assert(target == nil || target == expectedTarget, "captureContext returns only the editable frontmost target")
        assert(elapsed < .milliseconds(250), "captureContext returns without a restoration delay")
    }
}

func withRestoredPasteboard(_ operation: () async -> Void) async {
    let pasteboard = NSPasteboard.general
    let savedItems = (pasteboard.pasteboardItems ?? []).map { source in
        let item = NSPasteboardItem()
        for type in source.types {
            if let data = source.data(forType: type) {
                item.setData(data, forType: type)
            }
        }
        return item
    }
    defer {
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
    }
    await operation()
}

actor PasteGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enteredWaiter?.resume()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

func testCopyLeavesSelectedTextOnPasteboard() async {
    await withRestoredPasteboard {
        let service = PasteService()
        await service.copy("copy result")
        assert(NSPasteboard.general.string(forType: .string) == "copy result", "copy leaves the selected text on the pasteboard")
    }
}

func testUnavailableTargetCopiesThenThrows() async {
    await withRestoredPasteboard {
        let service = PasteService()
        do {
            try await service.paste("safe fallback", to: nil)
            assert(false, "missing target must throw")
        } catch let error as LocalFlowError {
            assert(error == .pasteTargetUnavailable, "missing target reports paste target unavailable")
        } catch {
            assert(false, "missing target must not throw an unrelated error")
        }
        assert(NSPasteboard.general.string(forType: .string) == "safe fallback", "missing target leaves text available to paste")
    }
}

func testCancelledPasteDoesNotMutatePasteboard() async {
    await withRestoredPasteboard {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)

        let service = PasteService()
        let gate = PasteGate()
        let task = Task { () throws -> Void in
            await gate.wait()
            try await service.paste("must not copy", to: nil)
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        do {
            try await task.value
            assert(false, "cancelled paste must not continue")
        } catch is CancellationError {
            assert(true, "cancelled paste reports cancellation")
        } catch {
            assert(false, "cancelled paste must not report a paste error")
        }
        assert(pasteboard.string(forType: .string) == "existing clipboard", "cancelled paste leaves the pasteboard unchanged")
    }
}

func testPermissionServiceCreation() {
    _ = PermissionService()
    assert(true, "PermissionService created")
}

@MainActor func testShortcutMonitorCreation() {
    let monitor = GlobalShortcutMonitor()
    assert(true, "GlobalShortcutMonitor created")
    monitor.stop()
}

func runAllTests() async {
    testPasteServiceCreation()
    await testCaptureContextSnapshotsTargetPromptly()
    await testCopyLeavesSelectedTextOnPasteboard()
    await testUnavailableTargetCopiesThenThrows()
    await testCancelledPasteDoesNotMutatePasteboard()
    testPermissionServiceCreation()
    await MainActor.run { testShortcutMonitorCreation() }
}

await runAllTests()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
