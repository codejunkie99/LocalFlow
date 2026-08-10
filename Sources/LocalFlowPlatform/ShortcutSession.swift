import Foundation

@MainActor public protocol ShortcutMonitoring: AnyObject {
    var delegate: (any ShortcutDelegate)? { get set }
    func start()
    func stop()
}

@MainActor public final class ShortcutSession {
    private let monitor: any ShortcutMonitoring
    private let handler: Handler
    private var started = false

    public init(
        monitor: any ShortcutMonitoring,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.handler = Handler(onPress: onPress, onRelease: onRelease)
    }

    public func start() {
        guard !started else { return }
        started = true
        monitor.delegate = handler
        monitor.start()
    }

    public func stop() {
        guard started else { return }
        started = false
        monitor.stop()
        monitor.delegate = nil
    }

    private final class Handler: ShortcutDelegate {
        private let onPress: () -> Void
        private let onRelease: () -> Void

        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }

        func shortcutPressed() { onPress() }
        func shortcutReleased() { onRelease() }
    }
}
