import Foundation

public protocol Transcribing: Sendable { func prepare() async throws; func start() async throws; func stop() async throws -> String }
public protocol Rewriting: Sendable { func prewarm(); func rewrite(_ text: String, deadline: Duration) async -> String }
public protocol Pasting: Sendable {
    func captureContext() async -> PasteTarget?
    func paste(_ text: String, to target: PasteTarget?) async throws
    func copy(_ text: String) async
}

@MainActor public final class DictationCoordinator {
    public private(set) var phase: DictationPhase = .idle
    private let transcriber: any Transcribing
    private let rewriter: any Rewriting
    private let paster: any Pasting
    private let onPhaseChange: @MainActor (DictationPhase) -> Void
    private var activeTarget: PasteTarget?

    public init(
        transcriber: any Transcribing,
        rewriter: any Rewriting,
        paster: any Pasting,
        onPhaseChange: @escaping @MainActor (DictationPhase) -> Void = { _ in }
    ) {
        self.transcriber = transcriber
        self.rewriter = rewriter
        self.paster = paster
        self.onPhaseChange = onPhaseChange
    }

    public func prepare() async throws {
        transition(to: .preparing("Preparing Apple speech"))
        try await transcriber.prepare()
        rewriter.prewarm()
        transition(to: .idle)
    }

    public func press() async throws {
        guard !phase.isBusy else { return }
        activeTarget = await paster.captureContext()
        do {
            try await transcriber.start()
            transition(to: .listening)
        } catch {
            activeTarget = nil
            throw error
        }
    }

    public func release(cleanupEnabled: Bool) async throws -> DictationResult? {
        guard phase == .listening else { return nil }
        do {
            let total = ContinuousClock.now
            transition(to: .finalizing)
            let speech = ContinuousClock.now
            let raw = try await transcriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw LocalFlowError.emptyTranscript }
            let speechMS = speech.duration(to: .now).milliseconds
            let rewrite = ContinuousClock.now
            transition(to: cleanupEnabled ? .rewriting : .pasting)
            let output = cleanupEnabled ? await rewriter.rewrite(raw, deadline: .seconds(2)) : raw
            let cleaned = cleanupEnabled && output != raw ? output : nil
            let rewriteMS = cleanupEnabled ? rewrite.duration(to: .now).milliseconds : 0
            let target = activeTarget
            let paste = ContinuousClock.now
            transition(to: .pasting)
            let didPaste: Bool
            do {
                try await paster.paste(output, to: target)
                didPaste = true
            } catch let error as LocalFlowError where error == .pasteTargetUnavailable {
                didPaste = false
            }
            let sample = LatencySample(timestamp: .now, speechFinalizationMilliseconds: speechMS, rewriteMilliseconds: rewriteMS, pasteMilliseconds: paste.duration(to: .now).milliseconds, totalMilliseconds: total.duration(to: .now).milliseconds, usedRawFallback: cleanupEnabled && cleaned == nil)
            activeTarget = nil
            transition(to: .idle)
            return DictationResult(rawText: raw, cleanedText: cleaned, finalText: output, latency: sample, target: target, didPaste: didPaste)
        } catch {
            activeTarget = nil
            let localError = error as? LocalFlowError ?? .transcriptionFailed("internal")
            transition(to: .failed(localError))
            throw error
        }
    }

    private func transition(to nextPhase: DictationPhase) {
        phase = nextPhase
        onPhaseChange(nextPhase)
    }
}

private extension Duration { var milliseconds: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 } }
