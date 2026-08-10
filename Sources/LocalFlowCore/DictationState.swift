import Foundation

public enum LocalFlowError: Error, Equatable, Sendable {
    case microphoneDenied, speechDenied, accessibilityDenied, speechAssetUnavailable
    case unsupportedLocale(String), transcriptionFailed(String), emptyTranscript, pasteFailed, pasteTargetUnavailable
}

public enum DictationPhase: Equatable, Sendable {
    case idle, preparing(String), listening, finalizing, rewriting, pasting, failed(LocalFlowError)
    public var isBusy: Bool {
        switch self {
        case .preparing, .listening, .finalizing, .rewriting, .pasting: true
        case .idle, .failed: false
        }
    }
}
