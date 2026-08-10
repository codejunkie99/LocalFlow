import Foundation
import AppKit
import CoreGraphics

@MainActor public protocol ShortcutDelegate: AnyObject {
    func shortcutPressed()
    func shortcutReleased()
}

@MainActor public final class GlobalShortcutMonitor: ShortcutMonitoring {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var localKeyDown: Any?
    private var localKeyUp: Any?
    public weak var delegate: (any ShortcutDelegate)?

    public init() {}

    public func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event, isDown: true)
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyEvent(event, isDown: false)
        }
        localKeyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event, isDown: true)
            return event
        }
        localKeyUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyEvent(event, isDown: false)
            return event
        }
    }

    private var isOptionHeld = false
    private var isSpaceHeld = false
    private var shortcutActive = false

    private func handleFlagsChanged(_ event: NSEvent) {
        let optionNow = event.modifierFlags.contains(.option)
        if optionNow != isOptionHeld {
            isOptionHeld = optionNow
            evaluateShortcut()
        }
    }

    private func handleKeyEvent(_ event: NSEvent, isDown: Bool) {
        guard event.keyCode == 49 else { return }
        guard !event.isARepeat else { return }
        if isDown {
            isSpaceHeld = true
            evaluateShortcut()
        } else {
            isSpaceHeld = false
            evaluateShortcut()
        }
    }

    private func evaluateShortcut() {
        let active = isOptionHeld && isSpaceHeld
        if active && !shortcutActive {
            shortcutActive = true
            delegate?.shortcutPressed()
        } else if !active && shortcutActive {
            shortcutActive = false
            delegate?.shortcutReleased()
        }
    }

    public func stop() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = keyUpMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyDown { NSEvent.removeMonitor(m) }
        if let m = localKeyUp { NSEvent.removeMonitor(m) }
        localMonitor = nil; globalMonitor = nil
        keyDownMonitor = nil; keyUpMonitor = nil
        localKeyDown = nil; localKeyUp = nil
        isOptionHeld = false; isSpaceHeld = false
        shortcutActive = false
    }
}
