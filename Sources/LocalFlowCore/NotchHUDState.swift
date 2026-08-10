import Foundation

public enum NotchHUDTone: Sendable, Equatable {
    case idle
    case listening
    case processing
    case success
    case failure
}

public enum NotchPresentationMode: Sendable, Equatable {
    case compact
    case result
    case history
}

public struct NotchHUDSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum NotchHUDLayout {
    public static let minimumWidth = 220.0
    public static let defaultWidth = 280.0
    public static let maximumWidth = 420.0

    public static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    public static func size(
        for mode: NotchPresentationMode,
        preferredWidth: Double
    ) -> NotchHUDSize {
        let preferred = clampedWidth(preferredWidth)
        return switch mode {
        case .compact:
            NotchHUDSize(width: 170, height: 38)
        case .result:
            NotchHUDSize(width: min(max(preferred + 240, 460), 620), height: 148)
        case .history:
            NotchHUDSize(width: min(max(preferred + 280, 500), 680), height: 360)
        }
    }
}

public struct NotchHUDState: Sendable, Equatable {
    public let isVisible: Bool
    public let tone: NotchHUDTone
    public let label: String
    public let autoDismissAfter: Duration?

    public init(
        isVisible: Bool,
        tone: NotchHUDTone,
        label: String,
        autoDismissAfter: Duration? = nil
    ) {
        self.isVisible = isVisible
        self.tone = tone
        self.label = label
        self.autoDismissAfter = autoDismissAfter
    }

    public static let hidden = NotchHUDState(
        isVisible: false,
        tone: .idle,
        label: ""
    )

    public static let listening = NotchHUDState(
        isVisible: true,
        tone: .listening,
        label: "Listening"
    )

    public static func processing(_ label: String) -> NotchHUDState {
        NotchHUDState(isVisible: true, tone: .processing, label: label)
    }

    public static func success(milliseconds: Double) -> NotchHUDState {
        NotchHUDState(
            isVisible: true,
            tone: .success,
            label: "Pasted · \(Int(milliseconds.rounded())) ms",
            autoDismissAfter: .milliseconds(700)
        )
    }

    public static func failure(_ error: LocalFlowError) -> NotchHUDState {
        NotchHUDState(
            isVisible: true,
            tone: .failure,
            label: safeMessage(for: error),
            autoDismissAfter: .milliseconds(2_500)
        )
    }

    private static func safeMessage(for error: LocalFlowError) -> String {
        switch error {
        case .microphoneDenied: "Microphone permission needed"
        case .speechDenied: "Speech permission needed"
        case .accessibilityDenied: "Accessibility permission needed"
        case .speechAssetUnavailable: "Speech model unavailable"
        case .unsupportedLocale: "Language not supported"
        case .transcriptionFailed: "Transcription failed"
        case .emptyTranscript: "No speech detected"
        case .pasteFailed: "Paste failed"
        case .pasteTargetUnavailable: "Copied · target unavailable"
        }
    }
}
