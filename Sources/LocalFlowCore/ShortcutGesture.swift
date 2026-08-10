import Foundation

public enum ShortcutGestureAction: Sendable, Equatable {
    case start
    case keepListening
    case stop
    case none
}

public struct ShortcutGesture: Sendable {
    private let tapThreshold: Duration
    private var pressedAt: ContinuousClock.Instant?
    private var toggleArmed = false

    public init(tapThreshold: Duration = .milliseconds(250)) {
        self.tapThreshold = tapThreshold
    }

    public mutating func pressed(at instant: ContinuousClock.Instant) -> ShortcutGestureAction {
        pressedAt = instant
        return toggleArmed ? .none : .start
    }

    public mutating func released(at instant: ContinuousClock.Instant) -> ShortcutGestureAction {
        guard let pressedAt else { return .none }
        self.pressedAt = nil

        if toggleArmed {
            toggleArmed = false
            return .stop
        }
        if pressedAt.duration(to: instant) <= tapThreshold {
            toggleArmed = true
            return .keepListening
        }
        return .stop
    }
}
