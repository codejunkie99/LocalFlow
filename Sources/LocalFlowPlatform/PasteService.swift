import Foundation
import AppKit
import CoreGraphics
import LocalFlowCore

public actor PasteService: Pasting {
    private var capturedClipboard: String?
    private var hasCapturedClipboard = false
    private var capturedFocusElement: AXElementBox?
    private var capturedAnchor: CursorAnchor?
    private static let markerType = NSPasteboard.PasteboardType("dev.localflow.paste-session")
    private var sessionMarker: String?
    private var pendingRestoration: Task<Void, Never>?
    private var isOperationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    deinit { pendingRestoration?.cancel() }

    public func captureContext() async -> PasteTarget? {
        await acquireOperation()
        defer { releaseOperation() }

        guard !Task.isCancelled else { return nil }
        let capture = await MainActor.run { () -> (PasteTarget, AXElementBox?, CursorAnchor?)? in
            guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
            guard AXIsProcessTrusted() else {
                return (PasteTarget(processIdentifier: application.processIdentifier), nil, nil)
            }
            guard let focus = Self.editableFocus(processIdentifier: application.processIdentifier) else {
                return nil
            }
            let target = PasteTarget(
                processIdentifier: application.processIdentifier,
                cursorAnchor: focus.anchor
            )
            return (target, AXElementBox(element: focus.element), focus.anchor)
        }
        guard let capture else {
            capturedFocusElement = nil
            capturedAnchor = nil
            return nil
        }
        capturedFocusElement = capture.1
        capturedAnchor = capture.2
        guard !Task.isCancelled else { return nil }
        if pendingRestoration == nil {
            captureClipboard()
        }
        return capture.0
    }

    private nonisolated static func editableFocus(
        processIdentifier: pid_t
    ) -> (element: AXUIElement, anchor: CursorAnchor?)? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = focusedElement(of: application) else { return nil }

        var roleValue: CFTypeRef?
        let role = if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String {
            role
        } else {
            ""
        }

        var valueSettable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueSettable
        ) == .success && valueSettable.boolValue

        var selectedRangeSettable = DarwinBoolean(false)
        let canSetSelection = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeSettable
        ) == .success && selectedRangeSettable.boolValue

        let isTextRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        guard canSetSelection || (isTextRole && canSetValue) else { return nil }
        return (focusedElement, cursorAnchor(of: focusedElement))
    }

    private nonisolated static func focusedElement(of application: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        return (focusedValue as! AXUIElement)
    }

    private nonisolated static func cursorAnchor(of element: AXUIElement) -> CursorAnchor? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return CursorAnchor(location: range.location, length: range.length)
    }

    private nonisolated static func setCursorAnchor(_ anchor: CursorAnchor, on element: AXUIElement) {
        var range = CFRange(location: anchor.location, length: anchor.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
    }

    private func restoreCursor(to target: PasteTarget, element: AXElementBox?, anchor: CursorAnchor?) async {
        guard element != nil || anchor != nil else { return }
        await MainActor.run {
            let application = AXUIElementCreateApplication(target.processIdentifier)
            let targetElement: AXUIElement
            if let element = element?.element {
                targetElement = element
                AXUIElementSetAttributeValue(
                    application,
                    kAXFocusedUIElementAttribute as CFString,
                    element
                )
            } else if let focused = Self.focusedElement(of: application) {
                targetElement = focused
            } else {
                return
            }
            if let anchor {
                Self.setCursorAnchor(anchor, on: targetElement)
            }
        }
    }

    public func copy(_ text: String) async {
        await acquireOperation()
        defer { releaseOperation() }
        copyAndInvalidate(text)
    }

    public func paste(_ text: String, to target: PasteTarget?) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        var pastedMarker: String?

        do {
            try Task.checkCancellation()
            await awaitPendingRestoration()
            try Task.checkCancellation()
            captureClipboardIfNeeded()

            await MainActor.run { NSApplication.shared.keyWindow?.resignKey() }
            try Task.checkCancellation()

            guard let target else {
                try copyThenThrow(text, error: .pasteTargetUnavailable)
            }

            let activated = await MainActor.run { () -> Bool in
                guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
                      !application.isTerminated else { return false }
                return application.activate(options: [])
            }
            try Task.checkCancellation()
            guard activated else {
                try copyThenThrow(text, error: .pasteTargetUnavailable)
            }

            try await Task.sleep(for: .milliseconds(90))
            try Task.checkCancellation()
            let isTargetFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            }
            try Task.checkCancellation()
            guard isTargetFrontmost else {
                try copyThenThrow(text, error: .pasteTargetUnavailable)
            }

            guard AXIsProcessTrusted() else {
                try copyThenThrow(text, error: .accessibilityDenied)
            }

            await restoreCursor(
                to: target,
                element: capturedFocusElement,
                anchor: capturedAnchor ?? target.cursorAnchor
            )
            try Task.checkCancellation()

            let marker = UUID().uuidString
            let pasteboard = NSPasteboard.general
            try Task.checkCancellation()
            sessionMarker = marker
            pastedMarker = marker
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            pasteboard.setString(marker, forType: Self.markerType)

            try postCommandV()
            scheduleRestoration(marker: marker)
        } catch {
            if error is CancellationError {
                if let pastedMarker {
                    restoreClipboard(marker: pastedMarker)
                } else {
                    discardUnrestoredSnapshot()
                }
            }
            throw error
        }
    }

    private func acquireOperation() async {
        guard isOperationActive else {
            isOperationActive = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            isOperationActive = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func awaitPendingRestoration() async {
        guard let pendingRestoration else { return }
        await pendingRestoration.value
    }

    private func captureClipboard() {
        capturedClipboard = NSPasteboard.general.string(forType: .string)
        hasCapturedClipboard = true
    }

    private func captureClipboardIfNeeded() {
        guard !hasCapturedClipboard else { return }
        captureClipboard()
    }

    private func copyThenThrow(_ text: String, error: LocalFlowError) throws -> Never {
        try Task.checkCancellation()
        copyAndInvalidate(text)
        throw error
    }

    private func copyAndInvalidate(_ text: String) {
        pendingRestoration?.cancel()
        invalidateSession()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func discardUnrestoredSnapshot() {
        guard sessionMarker == nil else { return }
        capturedClipboard = nil
        hasCapturedClipboard = false
    }

    private func postCommandV() throws {
        try Task.checkCancellation()
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        try Task.checkCancellation()
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func scheduleRestoration(marker: String) {
        pendingRestoration = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                await self?.restoreClipboard(marker: marker)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func restoreClipboard(marker: String) {
        guard sessionMarker == marker else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: Self.markerType) == marker else {
            invalidateSession()
            return
        }

        let captured = capturedClipboard
        let hadCapturedClipboard = hasCapturedClipboard
        pasteboard.clearContents()
        if hadCapturedClipboard, let captured {
            pasteboard.setString(captured, forType: .string)
        }
        invalidateSession()
    }

    private func invalidateSession() {
        capturedClipboard = nil
        hasCapturedClipboard = false
        capturedFocusElement = nil
        capturedAnchor = nil
        sessionMarker = nil
        pendingRestoration = nil
    }
}

private struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}
