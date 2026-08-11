import AppKit
import SwiftUI
import LocalFlowCore

private final class TranscriptNotchPanel: NSPanel {
    var permitsKey = false

    override var canBecomeKey: Bool { permitsKey }
}

@MainActor final class NotchHUDController {
    private let panel: TranscriptNotchPanel
    private let viewModel: NotchHUDViewModel
    private let hostingView: NSHostingView<NotchHUDView>
    private var dismissalTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var screenChangeTask: Task<Void, Never>?
    private var localHistoryClickMonitor: Any?
    private var globalHistoryClickMonitor: Any?
    private var currentState: NotchHUDState = .hidden
    private var preferredWidth: Double
    private var pointerInteractionActive = false
    private var searchFocused = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        let storedWidth = UserDefaults.standard.object(forKey: "notchWidth") as? Double
            ?? NotchHUDLayout.defaultWidth
        let initialWidth = NotchHUDLayout.clampedWidth(storedWidth)
        let initialSize = NotchHUDLayout.size(for: .compact, preferredWidth: initialWidth)
        let viewModel = NotchHUDViewModel(width: initialWidth)
        self.viewModel = viewModel
        self.hostingView = NSHostingView(rootView: NotchHUDView(model: viewModel))
        self.preferredWidth = initialWidth
        panel = TranscriptNotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hostingView
        panel.alphaValue = 0

        viewModel.onModeChange = { [weak self] mode in self?.apply(mode: mode) }
        viewModel.onInteractionChange = { [weak self] active in self?.setInteractionActive(active) }
        viewModel.onSearchFocusChange = { [weak self] focused in self?.setSearchFocused(focused) }
        viewModel.onCollapseHistory = { [weak self] in self?.collapseHistory() }

        screenChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                self.reposition(size: self.currentSize, animated: false)
            }
        }
    }

    isolated deinit {
        dismissalTask?.cancel()
        feedbackTask?.cancel()
        hideTask?.cancel()
        screenChangeTask?.cancel()
        if let localHistoryClickMonitor { NSEvent.removeMonitor(localHistoryClickMonitor) }
        if let globalHistoryClickMonitor { NSEvent.removeMonitor(globalHistoryClickMonitor) }
    }

    func setActions(onCopy: @escaping (TranscriptSelection) -> Void) {
        viewModel.onCopy = onCopy
    }

    func setHistoryQuery(_ query: @escaping (String, TranscriptSourceFilter) -> Void) {
        viewModel.onHistoryQueryChange = query
    }

    func show(_ state: NotchHUDState) {
        dismissalTask?.cancel()
        hideTask?.cancel()
        currentState = state

        guard state.isVisible else {
            hide()
            return
        }

        viewModel.state = state
        viewModel.currentResult = nil
        viewModel.feedback = nil
        viewModel.searchText = ""
        viewModel.sourceFilter = .all
        apply(mode: .compact, animated: !reduceMotion)
        showPanel()

        if let delay = state.autoDismissAfter {
            scheduleDismissal(after: delay)
        }
    }

    func presentResult(_ result: DictationResult) {
        dismissalTask?.cancel()
        hideTask?.cancel()
        currentState = .success(milliseconds: result.latency.totalMilliseconds)
        viewModel.state = currentState
        viewModel.currentResult = result
        viewModel.searchText = ""
        viewModel.sourceFilter = .all
        viewModel.feedback = nil
        apply(mode: .result, animated: !reduceMotion)
        showPanel()
        scheduleResultDismissal()
    }

    func updateHistorySnapshot(_ snapshot: TranscriptHistorySnapshot) {
        viewModel.updateHistorySnapshot(snapshot)
    }

    func showFeedback(_ feedback: String) {
        feedbackTask?.cancel()
        viewModel.feedback = feedback
        feedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_200))
            } catch {
                return
            }
            guard self?.viewModel.feedback == feedback else { return }
            self?.viewModel.feedback = nil
        }
    }

    func hide() {
        dismissalTask?.cancel()
        feedbackTask?.cancel()
        currentState = .hidden
        removeHistoryOutsideClickMonitors()
        clearSearchFocusAndResign()

        guard panel.isVisible else {
            finishHide()
            return
        }

        let fadeDuration = reduceMotion ? 0.08 : 0.14
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(fadeDuration))
            } catch {
                return
            }
            guard self?.currentState == .hidden else { return }
            self?.finishHide()
        }
    }

    func setWidth(_ width: Double) {
        let clamped = NotchHUDLayout.clampedWidth(width)
        preferredWidth = clamped
        viewModel.width = clamped
        reposition(size: currentSize, animated: panel.isVisible && !reduceMotion)
    }

    private var currentSize: NotchHUDSize {
        NotchHUDLayout.size(for: viewModel.mode, preferredWidth: preferredWidth)
    }

    private func apply(mode: NotchPresentationMode, animated: Bool = true) {
        viewModel.mode = mode
        panel.ignoresMouseEvents = mode == .compact

        if mode == .history {
            viewModel.onHistoryQueryChange?(viewModel.searchText, viewModel.sourceFilter)
            dismissalTask?.cancel()
            dismissalTask = nil
            clearSearchFocusAndResign()
            installHistoryOutsideClickMonitors()
        } else {
            removeHistoryOutsideClickMonitors()
            clearSearchFocusAndResign()
        }

        reposition(size: currentSize, animated: animated && !reduceMotion)
    }

    private func setInteractionActive(_ active: Bool) {
        guard pointerInteractionActive != active else { return }
        pointerInteractionActive = active
        updateResultDismissal()
    }

    private func setSearchFocused(_ focused: Bool) {
        guard viewModel.mode == .history else {
            searchFocused = false
            panel.permitsKey = false
            panel.resignKey()
            updateResultDismissal()
            return
        }

        searchFocused = focused
        panel.permitsKey = focused
        if focused {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
        }
        updateResultDismissal()
    }

    private func clearSearchFocusAndResign() {
        searchFocused = false
        viewModel.clearSearchFocus()
        panel.permitsKey = false
        panel.resignKey()
    }

    private func collapseHistory() {
        guard viewModel.mode == .history else { return }
        removeHistoryOutsideClickMonitors()
        clearSearchFocusAndResign()
        let destination: NotchPresentationMode = viewModel.currentResult == nil ? .compact : .result
        viewModel.mode = destination
        apply(mode: destination)
    }

    private func installHistoryOutsideClickMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if localHistoryClickMonitor == nil {
            localHistoryClickMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                guard let self,
                      self.viewModel.mode == .history,
                      event.window !== self.panel else { return event }
                self.collapseHistory()
                return event
            }
        }
        if globalHistoryClickMonitor == nil {
            globalHistoryClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                self?.collapseHistory()
            }
        }
    }

    private func removeHistoryOutsideClickMonitors() {
        if let localHistoryClickMonitor {
            NSEvent.removeMonitor(localHistoryClickMonitor)
            self.localHistoryClickMonitor = nil
        }
        if let globalHistoryClickMonitor {
            NSEvent.removeMonitor(globalHistoryClickMonitor)
            self.globalHistoryClickMonitor = nil
        }
    }

    private func updateResultDismissal() {
        guard viewModel.mode == .result else { return }
        if pointerInteractionActive || searchFocused {
            dismissalTask?.cancel()
            dismissalTask = nil
        } else {
            scheduleResultDismissal()
        }
    }

    private func scheduleResultDismissal() {
        guard viewModel.mode == .result, !pointerInteractionActive, !searchFocused else { return }
        scheduleDismissal(after: .seconds(4))
    }

    private func scheduleDismissal(after delay: Duration) {
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func showPanel() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func finishHide() {
        guard currentState == .hidden else { return }
        panel.orderOut(nil)
        viewModel.state = .hidden
        viewModel.currentResult = nil
        viewModel.feedback = nil
        pointerInteractionActive = false
        apply(mode: .compact, animated: false)
    }

    private func reposition(size: NotchHUDSize, animated: Bool) {
        guard let screen = activeScreen() else { return }

        let availableWidth = max(1, screen.visibleFrame.width - 24)
        let width = min(size.width, availableWidth)
        let minimumX = screen.visibleFrame.minX + 12
        let maximumX = max(minimumX, screen.visibleFrame.maxX - 12 - width)
        let centeredX = screen.frame.midX - width / 2
        let frame = NSRect(
            x: min(max(centeredX, minimumX), maximumX),
            y: screen.frame.maxY - size.height,
            width: width,
            height: size.height
        )

        guard panel.frame != frame else { return }
        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }

        let duration: TimeInterval = switch viewModel.mode {
        case .result: 0.26
        case .history: 0.30
        case .compact: 0.18
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func activeScreen() -> NSScreen? {
        let localPID = ProcessInfo.processInfo.processIdentifier
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPID != localPID,
           let windowInfo = CGWindowListCopyWindowInfo(
               [.optionOnScreenOnly, .excludeDesktopElements],
               kCGNullWindowID
           ) as? [[String: Any]] {
            for window in windowInfo {
                guard (window[kCGWindowOwnerPID as String] as? pid_t) == frontmostPID,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                      bounds.width > 100,
                      bounds.height > 100 else { continue }

                if let screen = NSScreen.screens.first(where: {
                    bounds.midX >= $0.frame.minX && bounds.midX < $0.frame.maxX
                }) {
                    return screen
                }
            }
        }

        if let currentScreen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) {
            return currentScreen
        }

        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
