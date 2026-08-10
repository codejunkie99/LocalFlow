import LocalFlowCore
import Foundation

actor FakeTranscriber: Transcribing {
    var prepared = false; var started = false; var stopped = false
    let result: String
    init(result: String = "hello world") { self.result = result }
    func prepare() async throws { prepared = true }
    func start() async throws { started = true }
    func stop() async throws -> String { stopped = true; return result }
}

actor FakeRewriter: Rewriting {
    var prewarmed = false
    let result: String?

    init(result: String? = nil) { self.result = result }

    nonisolated func prewarm() { Task { await setPrewarmed() } }
    private func setPrewarmed() { prewarmed = true }
    func rewrite(_ text: String, deadline: Duration) async -> String { result ?? "REWRITTEN: \(text)" }
}

actor FakePaster: Pasting {
    var contextCaptured = false
    var pasted: [(String, PasteTarget?)] = []
    var copied: [String] = []
    let error: LocalFlowError?
    let target = PasteTarget(processIdentifier: 42)

    init(error: LocalFlowError? = nil) { self.error = error }

    func captureContext() async -> PasteTarget? {
        contextCaptured = true
        return target
    }

    func paste(_ text: String, to target: PasteTarget?) async throws {
        if let error { throw error }
        pasted.append((text, target))
    }

    func copy(_ text: String) async { copied.append(text) }
}

@MainActor final class PhaseRecorder {
    var phases: [DictationPhase] = []
    func record(_ phase: DictationPhase) { phases.append(phase) }
}

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

// Test functions run from top-level async
func runAllTests() async {
    // testFailureLeavesCoordinatorRecoverable
    do {
        let transcriber = FakeTranscriber(result: "hello")
        let rewriter = FakeRewriter()
        let paster = FakePaster(error: .accessibilityDenied)
        let coordinator = await MainActor.run {
            DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster)
        }
        try! await coordinator.press()
        do {
            _ = try await coordinator.release(cleanupEnabled: false)
            assert(false, "paste failure must throw")
        } catch {
            assert(await coordinator.phase == .failed(.accessibilityDenied), "failure exits busy phase")
        }
        try! await coordinator.press()
        assert(await coordinator.phase == .listening, "next press recovers after failure")
    }

    // testUnavailablePasteTargetReturnsTranscriptForManualCopy
    do {
        let transcriber = FakeTranscriber(result: "copy this instead")
        let rewriter = FakeRewriter()
        let paster = FakePaster(error: .pasteTargetUnavailable)
        let coordinator = await MainActor.run {
            DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster)
        }
        try! await coordinator.press()
        let result = try! await coordinator.release(cleanupEnabled: false)
        assert(await coordinator.phase == .idle, "unavailable paste target still completes dictation")
        assert(result?.finalText == "copy this instead", "unavailable target returns transcript text")
        assert(result?.didPaste == false, "unavailable target marks result for transcript presentation")
    }

    // testPhaseSequence
    do {
        let transcriber = FakeTranscriber(result: "send the report")
        let rewriter = FakeRewriter()
        let paster = FakePaster()
        let recorder = await MainActor.run { PhaseRecorder() }
        let coordinator = await MainActor.run {
            DictationCoordinator(
                transcriber: transcriber,
                rewriter: rewriter,
                paster: paster,
                onPhaseChange: { recorder.record($0) }
            )
        }
        try! await coordinator.prepare()
        try! await coordinator.press()
        _ = try! await coordinator.release(cleanupEnabled: true)
        let phases = await recorder.phases
        assert(
            phases == [
                .preparing("Preparing Apple speech"),
                .idle,
                .listening,
                .finalizing,
                .rewriting,
                .pasting,
                .idle,
            ],
            "reports every pipeline phase in order"
        )
    }

    // testFullFlow
    do {
        let transcriber = FakeTranscriber(result: "um send the report today")
        let rewriter = FakeRewriter()
        let paster = FakePaster()
        let coordinator = await MainActor.run { DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster) }
        try! await coordinator.prepare()
        assert(await coordinator.phase == .idle, "phase idle after prepare")
        try! await coordinator.press()
        assert(await coordinator.phase == .listening, "phase listening after press")
        assert(await paster.contextCaptured, "press captures paste context")
        let result = try! await coordinator.release(cleanupEnabled: true)
        assert(await coordinator.phase == .idle, "phase idle after release")
        assert(result?.rawText == "um send the report today", "result preserves raw text")
        assert(result?.cleanedText == "REWRITTEN: um send the report today", "result preserves cleaned text")
        assert(result?.finalText == "REWRITTEN: um send the report today", "result exposes pasted text")
        assert(result?.target == PasteTarget(processIdentifier: 42), "result preserves paste target")
        assert(result?.didPaste == true, "successful target records automatic paste")
        assert((result?.latency.totalMilliseconds ?? 0) > 0, "result contains latency")
        assert(result?.latency.usedRawFallback == false, "distinct cleanup is not fallback")
        let pasted = await paster.pasted
        assert(pasted.count == 1, "one rewritten value is pasted")
        assert(pasted.first?.0 == "REWRITTEN: um send the report today", "rewritten text pasted")
        assert(pasted.first?.1 == PasteTarget(processIdentifier: 42), "paste uses captured target")
    }

    // testRawFallbackFlow
    do {
        let transcriber = FakeTranscriber(result: "raw text")
        let rewriter = FakeRewriter()
        let paster = FakePaster()
        let coordinator = await MainActor.run { DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster) }
        try! await coordinator.prepare()
        try! await coordinator.press()
        let result = try! await coordinator.release(cleanupEnabled: false)
        assert(await coordinator.phase == .idle, "phase idle after raw release")
        assert(result?.rawText == "raw text", "raw mode preserves raw text")
        assert(result?.cleanedText == nil, "raw mode has no cleaned value")
        assert(result?.finalText == "raw text", "raw mode returns raw final text")
        assert(result?.latency.usedRawFallback == false, "raw mode not counted as fallback")
        let pasted = await paster.pasted
        assert(pasted.first?.0 == "raw text", "raw text pasted")
        assert(pasted.first?.1 == PasteTarget(processIdentifier: 42), "raw paste uses captured target")
    }

    // testCleanupFallbackFlow
    do {
        let transcriber = FakeTranscriber(result: "unchanged text")
        let rewriter = FakeRewriter(result: "unchanged text")
        let paster = FakePaster()
        let coordinator = await MainActor.run { DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster) }
        try! await coordinator.prepare()
        try! await coordinator.press()
        let result = try! await coordinator.release(cleanupEnabled: true)
        assert(result?.cleanedText == nil, "unchanged cleanup has no cleaned value")
        assert(result?.finalText == "unchanged text", "fallback pastes raw text")
        assert(result?.latency.usedRawFallback == true, "unchanged cleanup is raw fallback")
    }

    // testReleaseWhenNotListening
    do {
        let transcriber = FakeTranscriber()
        let rewriter = FakeRewriter()
        let paster = FakePaster()
        let coordinator = await MainActor.run { DictationCoordinator(transcriber: transcriber, rewriter: rewriter, paster: paster) }
        let result = try! await coordinator.release(cleanupEnabled: true)
        assert(result == nil, "release while idle returns nil")
    }
}

// Top-level async entry
await runAllTests()
print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
