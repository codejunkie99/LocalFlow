import Foundation
import SwiftUI
import LocalFlowCore
import LocalFlowPlatform

@MainActor public final class AppModel: ObservableObject {
    @Published public var phase: DictationPhase = .idle
    @Published public var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published public var lastLatency: LatencySample?
    @Published public var permissionSummary: String = ""
    @Published public private(set) var microphonePermission: PermissionState = .notDetermined
    @Published public private(set) var speechPermission: PermissionState = .notDetermined
    @Published public private(set) var accessibilityPermission: PermissionState = .denied
    @Published public private(set) var notchWidth: Double
    @Published public private(set) var transcriptHistory = TranscriptHistory()

    private var coordinator: DictationCoordinator?
    private var shortcutSession: ShortcutSession?
    private let speechService = AppleSpeechService()
    private let rewriteService = AppleRewriteService()
    private let pasteService = PasteService()
    private let permissionService = PermissionService()
    private let logger = LocalFlowLogger()
    private let notchHUD = NotchHUDController()
    private var latencyReport = LatencyReport()
    private var shortcutGesture = ShortcutGesture()

    public init() {
        self.cleanupEnabled = UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true
        self.notchWidth = NotchHUDLayout.clampedWidth(
            UserDefaults.standard.object(forKey: "notchWidth") as? Double
                ?? NotchHUDLayout.defaultWidth
        )
        notchHUD.setWidth(notchWidth)
        notchHUD.setActions(
            onCopy: { [weak self] selection in self?.copy(selection) }
        )
    }

    public func start() {
        guard coordinator == nil else { return }
        let coordinator = DictationCoordinator(
            transcriber: speechService,
            rewriter: rewriteService,
            paster: pasteService,
            onPhaseChange: { [weak self] phase in self?.applyPhase(phase) }
        )
        self.coordinator = coordinator

        let monitor = GlobalShortcutMonitor()
        let session = ShortcutSession(
            monitor: monitor,
            onPress: { [weak self] in self?.shortcutPressed() },
            onRelease: { [weak self] in self?.shortcutReleased() }
        )
        session.start()
        self.shortcutSession = session

        Task {
            do {
                try await coordinator.prepare()
            } catch {
                logger.logError("prepare: \(String(describing: error))")
                showFailure(error)
            }
        }
        refreshPermissionSummary()
    }

    public func refreshPermissionSummary() {
        let mic = permissionService.microphoneState
        let speech = permissionService.speechState
        let access = permissionService.accessibilityState
        microphonePermission = mic
        speechPermission = speech
        accessibilityPermission = access
        var parts: [String] = []
        if mic != .granted { parts.append("Mic: \(mic)") }
        if speech != .granted { parts.append("Speech: \(speech)") }
        if access != .granted { parts.append("Accessibility: \(access)") }
        permissionSummary = parts.isEmpty ? "All permissions granted" : parts.joined(separator: " | ")
    }

    public func requestMicrophone() {
        Task {
            _ = await permissionService.requestMicrophone()
            refreshPermissionSummary()
        }
    }

    public func requestSpeech() {
        Task {
            _ = await permissionService.requestSpeech()
            refreshPermissionSummary()
        }
    }

    public func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    public func openMicrophoneSettings() {
        permissionService.openMicrophoneSettings()
    }

    public func openSpeechSettings() {
        permissionService.openSpeechSettings()
    }

    public func toggleCleanup() {
        cleanupEnabled.toggle()
    }

    public func toggleDictation() {
        switch phase {
        case .idle, .failed:
            Task { await handlePress() }
        case .listening:
            Task { await handleRelease() }
        case .preparing, .finalizing, .rewriting, .pasting:
            break
        }
    }

    public func setNotchWidth(_ width: Double) {
        let clamped = NotchHUDLayout.clampedWidth(width)
        notchWidth = clamped
        UserDefaults.standard.set(clamped, forKey: "notchWidth")
        notchHUD.setWidth(clamped)
    }

    private func shortcutPressed() {
        guard shortcutGesture.pressed(at: .now) == .start else { return }
        Task { await handlePress() }
    }

    private func shortcutReleased() {
        guard shortcutGesture.released(at: .now) == .stop else { return }
        Task { await handleRelease() }
    }

    private func handlePress() async {
        guard let coordinator else { return }
        do {
            try await coordinator.press()
        } catch {
            logger.logError("press: \(String(describing: error))")
            showFailure(error)
        }
        logger.logPhase(String(describing: phase))
    }

    private func handleRelease() async {
        guard let coordinator else { return }
        do {
            guard let result = try await coordinator.release(cleanupEnabled: cleanupEnabled) else { return }
            lastLatency = result.latency
            latencyReport.samples.append(result.latency)
            if latencyReport.samples.count > 20 {
                latencyReport.samples.removeFirst()
            }
            logger.logLatency(
                speechMS: result.latency.speechFinalizationMilliseconds,
                rewriteMS: result.latency.rewriteMilliseconds,
                pasteMS: result.latency.pasteMilliseconds,
                totalMS: result.latency.totalMilliseconds,
                fallback: result.latency.usedRawFallback
            )
            transcriptHistory.insert(result)
            if !result.didPaste {
                notchHUD.presentResult(result, history: transcriptHistory)
            }
        } catch {
            logger.logError("release: \(String(describing: error))")
            showFailure(error)
        }
        logger.logPhase(String(describing: phase))
    }

    private func applyPhase(_ nextPhase: DictationPhase) {
        phase = nextPhase
        switch nextPhase {
        case .idle:
            notchHUD.hide()
        case .preparing:
            break
        case .listening:
            notchHUD.show(.listening)
        case .finalizing:
            notchHUD.show(.processing("Transcribing"))
        case .rewriting:
            notchHUD.show(.processing("Cleaning up"))
        case .pasting:
            notchHUD.show(.processing("Pasting"))
        case .failed(let error):
            notchHUD.show(.failure(error))
        }
    }

    private func showFailure(_ error: any Error) {
        let localError = error as? LocalFlowError ?? .transcriptionFailed("internal")
        phase = .failed(localError)
        notchHUD.show(.failure(localError))
    }

    private func copy(_ selection: TranscriptSelection) {
        Task { [weak self] in
            guard let self else { return }
            await pasteService.copy(selection.text)
            notchHUD.showFeedback("Copied")
        }
    }

}
