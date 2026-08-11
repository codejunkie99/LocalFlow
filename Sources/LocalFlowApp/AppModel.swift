import Foundation
import SwiftUI
import CryptoKit
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
    @Published public private(set) var historyCount: Int = 0
    @Published public private(set) var updateState: UpdateState = .idle
    public let installedVersion: LocalFlowVersion

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
    private let historyStore: TranscriptHistoryStore?
    private var historyQueryTask: Task<Void, Never>?
    private var availableManifest: LocalFlowReleaseManifest?
    private let updateService: UpdateService

    public init(historyStore: TranscriptHistoryStore? = nil) {
        self.cleanupEnabled = UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true
        self.notchWidth = NotchHUDLayout.clampedWidth(
            UserDefaults.standard.object(forKey: "notchWidth") as? Double
                ?? NotchHUDLayout.defaultWidth
        )
        if let historyStore {
            self.historyStore = historyStore
        } else {
            do {
                self.historyStore = try TranscriptHistoryStore(
                    databaseURL: TranscriptHistoryStore.liveDatabaseURL()
                )
            } catch {
                self.historyStore = nil
                logger.logError("history_store:\(Self.privacySafeErrorCode(error))")
            }
        }
        let installedAppURL = Bundle.main.bundleURL
        let installedVersion = (
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ).flatMap { try? LocalFlowVersion($0) } ?? LocalFlowVersion(rawValue: "0.2.0")
        self.installedVersion = installedVersion
        self.updateService = UpdateService(
            configuration: UpdateService.Configuration(
                repositoryOwner: "codejunkie99",
                repositoryName: "LocalFlow",
                installedAppURL: installedAppURL,
                installedVersion: installedVersion,
                storedSigningIdentity: UserDefaults.standard.string(
                    forKey: "LocalFlowSigningIdentity"
                ),
                signingFingerprint: UserDefaults.standard.string(
                    forKey: "LocalFlowSigningFingerprint"
                )
            ),
            transport: URLSessionTransport(),
            runner: ProcessRunner()
        )
        notchHUD.setWidth(notchWidth)
        notchHUD.setActions(
            onCopy: { [weak self] selection in self?.copy(selection) }
        )
        notchHUD.setHistoryQuery { [weak self] search, source in
            Task { await self?.refreshHistory(search: search, source: source) }
        }
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
        Task { await refreshHistory(search: "", source: .all) }
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

    public func clearHistory() {
        guard let historyStore else { return }
        Task { [weak self] in
            do {
                try await historyStore.clear()
                await self?.refreshHistory(search: "", source: .all)
            } catch {
                self?.logger.logError("history_store:\(Self.privacySafeErrorCode(error))")
            }
        }
    }

    public func checkForUpdates() {
        guard phase == .idle else { return }
        updateState = .checking
        Task { [weak self] in
            guard let self else { return }
            let result: (state: UpdateState, manifest: LocalFlowReleaseManifest?)
            do {
                result = try await self.updateService.checkWithManifest(
                    currentVersion: self.installedVersion
                )
            } catch {
                result = (.failed(.network), nil)
            }
            await MainActor.run {
                self.updateState = result.state
                self.availableManifest = result.manifest
            }
        }
    }

    public func installUpdate() {
        guard let manifest = availableManifest else { return }
        updateState = .downloading(progress: 0)
        Task { [weak self] in
            guard let self else { return }
            let state = await self.updateService.install(manifest)
            await MainActor.run {
                self.updateState = state
                if state == .installing {
                    self.availableManifest = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
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
            if let historyStore {
                do {
                    try await historyStore.insert(result)
                } catch {
                    logger.logError("history_store:\(Self.privacySafeErrorCode(error))")
                }
            }
            await refreshHistory(search: "", source: .all)
            if !result.didPaste {
                notchHUD.presentResult(result)
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

    private func refreshHistory(search: String, source: TranscriptSourceFilter) async {
        guard let historyStore else {
            await MainActor.run {
                notchHUD.updateHistorySnapshot(.empty)
            }
            return
        }
        historyQueryTask?.cancel()
        historyQueryTask = Task { [weak self] in
            do {
                let snapshot = try await historyStore.snapshot(search: search, source: source)
                guard !Task.isCancelled else { return }
                self?.historyCount = snapshot.totalCount
                self?.notchHUD.updateHistorySnapshot(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.logError("history_store:\(Self.privacySafeErrorCode(error))")
                self?.historyCount = 0
                self?.notchHUD.updateHistorySnapshot(.empty)
            }
        }
    }

    private static func privacySafeErrorCode(_ error: any Error) -> Int {
        if let storeError = error as? TranscriptHistoryStore.StoreError,
           case .sqlite(let status, _) = storeError {
            return Int(status)
        }
        return (error as NSError).code
    }

}

public struct URLSessionTransport: UpdateTransport {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func download(from url: URL, to destination: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}

public func writeUpdateReceiptIfRequested() {
    guard let receiptPath = ProcessInfo.processInfo.environment["LOCALFLOW_UPDATE_RECEIPT"] else {
        return
    }
    let receiptURL = URL(fileURLWithPath: receiptPath)
    guard receiptURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
          let executable = Bundle.main.executableURL
    else {
        return
    }
    Task.detached {
        let digest = (try? sha256Hex(of: executable)) ?? ""
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let payload = """
        {"version":"\(version)","executable_sha256":"\(digest)","launched_at":\(Int(Date().timeIntervalSince1970))}
        """
        try? payload.write(to: receiptURL, atomically: true, encoding: .utf8)
    }
}

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    try handle.close()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
