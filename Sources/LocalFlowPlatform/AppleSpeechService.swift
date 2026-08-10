import Foundation
@preconcurrency import AVFoundation
import Speech
import LocalFlowCore

private final class ConverterInputState: @unchecked Sendable {
    var supplied = false
}

public actor AppleSpeechService: Transcribing {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var accumulator = TranscriptAccumulator()
    private var preparedLocale: Locale?
    private var resultTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Error>?
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?

    public init() {}

    public func prepare() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-IN")) else {
            throw LocalFlowError.unsupportedLocale("en-IN")
        }
        preparedLocale = locale
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }

    public func start() async throws {
        guard let locale = preparedLocale else { throw LocalFlowError.transcriptionFailed("not prepared") }
        accumulator = TranscriptAccumulator()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        let formats = await transcriber.availableCompatibleAudioFormats
        guard let target = formats.first else {
            throw LocalFlowError.transcriptionFailed("no compatible audio format")
        }
        try await analyzer.prepareToAnalyze(in: target)

        // Create audio input stream
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.streamContinuation = continuation

        // Start analyzer processing in background
        let analyzerTask = Task { [analyzer] in
            try await analyzer.start(inputSequence: stream)
        }
        self.analyzerTask = analyzerTask

        // Collect transcription results
        let resultTask = Task { [weak self, transcriber] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self.consumeResult(text: text, isFinal: result.isFinal)
                }
            } catch {
                // Stream completed or cancelled
            }
        }
        self.resultTask = resultTask
        self.transcriber = transcriber

        // Set up mic input
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw LocalFlowError.transcriptionFailed("audio converter unavailable")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer: buffer, converter: converter, format: target) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.analyzer = analyzer
    }

    public func stop() async throws -> String {
        guard let engine, let analyzer else { throw LocalFlowError.transcriptionFailed("not started") }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        // End input stream
        streamContinuation?.finish()
        streamContinuation = nil

        // Wait for analyzer to finish processing
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            throw LocalFlowError.transcriptionFailed("finalization failed: \(error.localizedDescription)")
        }

        // Wait briefly for final results
        try? await Task.sleep(for: .milliseconds(500))
        resultTask?.cancel()
        analyzerTask?.cancel()
        resultTask = nil
        analyzerTask = nil

        self.analyzer = nil
        self.transcriber = nil

        let final = accumulator.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LocalFlowError.emptyTranscript }
        return final
    }

    private func consumeResult(text: String, isFinal: Bool) {
        accumulator.accept(text, isFinal: isFinal)
    }

    private nonisolated static func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(format.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        var error: NSError?
        let inputState = ConverterInputState()
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !inputState.supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if let error { fputs("Audio conversion error: \(error)\n", stderr); return nil }
        return converted
    }
}
