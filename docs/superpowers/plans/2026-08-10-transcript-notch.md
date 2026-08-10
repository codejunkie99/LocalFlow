# Transcript Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a compact waveform-only recording notch that automatically expands into a copyable, pasteable transcript result and exposes a memory-only five-result filtered history plus a horizontally scrollable recent ten.

**Architecture:** Add transcript result and history values to `LocalFlowCore`, return the full in-memory result from `DictationCoordinator`, and teach `PasteService` to restore the application captured at dictation start. Keep one persistent SwiftUI root inside the existing `NSPanel`; a presentation mode drives panel geometry, pointer/key behavior, result content, and history content without persisting transcript text.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit `NSPanel`, Apple Speech `SpeechAnalyzer`, Foundation Models, `NSWorkspace`, Core Graphics paste events, standalone Swift test executables.

---

## File structure

**Create**

- `Sources/LocalFlowCore/TranscriptHistory.swift` — transcript record, source selection, filtering, and bounded in-memory history.
- `Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift` — history ordering, capacity, filter, search, and source tests.
- `Sources/LocalFlowApp/TranscriptResultView.swift` — automatically expanded current-result surface.
- `Sources/LocalFlowApp/TranscriptHistoryView.swift` — search, filter chips, five-result list, and recent-ten horizontal strip.
- `Sources/LocalFlowApp/ElongatedWaveform.swift` — reusable compact waveform renderer extracted from the current HUD file.

**Modify**

- `Sources/LocalFlowCore/DictationState.swift` — add the privacy-safe unavailable-target error.
- `Sources/LocalFlowCore/DictationCoordinator.swift` — capture a target and return `DictationResult` instead of latency alone.
- `Sources/LocalFlowCore/NotchHUDState.swift` — add presentation modes and deterministic panel geometry.
- `Sources/LocalFlowPlatform/PasteService.swift` — restore the captured application before history paste and add explicit Copy.
- `Sources/LocalFlowApp/NotchHUDView.swift` — become the mode-switching root view.
- `Sources/LocalFlowApp/NotchHUDController.swift` — animate panel geometry and toggle pointer/key behavior.
- `Sources/LocalFlowApp/AppModel.swift` — own the in-memory history and connect result actions.
- `Tests/LocalFlowCoreTests/DictationCoordinatorTests.swift` — assert raw, cleaned, final, target, and fallback results.
- `Tests/LocalFlowCoreTests/NotchHUDStateTests.swift` — assert compact, result, and history geometry.
- `Tests/LocalFlowPlatformTests/PasteMarkerTests.swift` — update protocol construction and copy behavior coverage.
- `README.md` and `docs/ARCHITECTURE.md` — document in-memory history and focus restoration.

### Task 1: Add the bounded in-memory transcript model

**Files:**
- Create: `Sources/LocalFlowCore/TranscriptHistory.swift`
- Create: `Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift`

- [ ] **Step 1: Write the failing history tests**

Create `Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift`:

```swift
import Foundation
import LocalFlowCore

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

func makeResult(_ index: Int, cleaned: Bool = true) -> DictationResult {
    let raw = "raw transcript \(index)"
    let clean = cleaned ? "clean transcript \(index)" : nil
    return DictationResult(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: Double(index)),
        rawText: raw,
        cleanedText: clean,
        finalText: clean ?? raw,
        latency: .zero,
        target: PasteTarget(processIdentifier: Int32(index + 10))
    )
}

var history = TranscriptHistory()
for index in 0..<12 { history.insert(makeResult(index, cleaned: index.isMultiple(of: 2))) }

assert(history.entries.count == 10, "history caps at ten")
assert(history.entries.first?.finalText == "clean transcript 11", "newest item is first")
assert(history.entries.last?.rawText == "raw transcript 2", "oldest overflow is removed")
assert(history.recent(limit: 10).count == 10, "recent strip returns ten")
assert(history.filtered(search: "TRANSCRIPT 8", source: .all, limit: 5).count == 1, "search is case insensitive")
assert(history.filtered(search: "", source: .raw, limit: 5).allSatisfy { $0.text.hasPrefix("raw") }, "raw filter selects raw text")
assert(history.filtered(search: "", source: .cleaned, limit: 5).allSatisfy { $0.text.hasPrefix("clean") }, "cleaned filter selects cleaned text")
assert(history.filtered(search: "", source: .cleaned, limit: 20).count == 5, "cleaned filter excludes fallback entries")

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
```

- [ ] **Step 2: Run the new test and verify red**

Run:

```bash
./scripts/run-tests.sh
```

Expected: compilation fails because `DictationResult`, `PasteTarget`, `TranscriptHistory`, and `TranscriptSourceFilter` do not exist.

- [ ] **Step 3: Implement the core values and history**

Create `Sources/LocalFlowCore/TranscriptHistory.swift`:

```swift
import Foundation

public struct PasteTarget: Sendable, Equatable {
    public let processIdentifier: Int32
    public init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
}

public struct DictationResult: Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let rawText: String
    public let cleanedText: String?
    public let finalText: String
    public let latency: LatencySample
    public let target: PasteTarget?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        rawText: String,
        cleanedText: String?,
        finalText: String,
        latency: LatencySample,
        target: PasteTarget?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.latency = latency
        self.target = target
    }
}

public enum TranscriptSourceFilter: String, CaseIterable, Sendable, Equatable {
    case all = "All"
    case raw = "Raw"
    case cleaned = "Cleaned"
}

public struct TranscriptSelection: Identifiable, Sendable, Equatable {
    public let record: DictationResult
    public let text: String
    public let source: TranscriptSourceFilter
    public var id: UUID { record.id }
}

public struct TranscriptHistory: Sendable, Equatable {
    public private(set) var entries: [DictationResult] = []
    public static let capacity = 10

    public init() {}

    public mutating func insert(_ result: DictationResult) {
        entries.removeAll { $0.id == result.id }
        entries.insert(result, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    public func recent(limit: Int = Self.capacity) -> [DictationResult] {
        Array(entries.prefix(max(0, limit)))
    }

    public func filtered(
        search: String,
        source: TranscriptSourceFilter,
        limit: Int = 5
    ) -> [TranscriptSelection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.compactMap { record -> TranscriptSelection? in
            let selected: (String, TranscriptSourceFilter)? = switch source {
            case .all:
                (record.finalText, record.cleanedText == nil ? .raw : .cleaned)
            case .raw:
                (record.rawText, .raw)
            case .cleaned:
                record.cleanedText.map { ($0, .cleaned) }
            }
            guard let selected else { return nil }
            guard query.isEmpty || selected.0.localizedCaseInsensitiveContains(query) else { return nil }
            return TranscriptSelection(record: record, text: selected.0, source: selected.1)
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run `./scripts/run-tests.sh`.

Expected: `TranscriptHistoryTests` passes and all existing tests remain green.

- [ ] **Step 5: Commit the core history**

```bash
git add Sources/LocalFlowCore/TranscriptHistory.swift Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift
git commit -m "feat: add memory-only transcript history"
```

### Task 2: Return transcript results from the coordinator

**Files:**
- Modify: `Sources/LocalFlowCore/DictationCoordinator.swift`
- Modify: `Tests/LocalFlowCoreTests/DictationCoordinatorTests.swift`

- [ ] **Step 1: Update fakes and write failing result assertions**

Change `FakePaster` in `DictationCoordinatorTests.swift` to:

```swift
actor FakePaster: Pasting {
    var contextCaptured = false
    var pasted: [(String, PasteTarget?)] = []
    var copied: [String] = []
    let error: LocalFlowError?
    let target = PasteTarget(processIdentifier: 42)

    init(error: LocalFlowError? = nil) { self.error = error }

    func captureContext() async -> PasteTarget? {
        contextCaptured = true
        return target
    }

    func paste(_ text: String, to target: PasteTarget?) async throws {
        if let error { throw error }
        pasted.append((text, target))
    }

    func copy(_ text: String) async { copied.append(text) }
}
```

Replace the full-flow result assertions with:

```swift
let result = try! await coordinator.release(cleanupEnabled: true)
assert(result?.rawText == "um send the report today", "result preserves raw text")
assert(result?.cleanedText == "REWRITTEN: um send the report today", "result preserves cleaned text")
assert(result?.finalText == "REWRITTEN: um send the report today", "result exposes pasted text")
assert(result?.target == PasteTarget(processIdentifier: 42), "result preserves paste target")
assert((result?.latency.totalMilliseconds ?? 0) > 0, "result contains latency")
let pasted = await paster.pasted
assert(pasted.map { $0.0 } == ["REWRITTEN: um send the report today"], "rewritten text pasted")
```

For raw mode assert:

```swift
let result = try! await coordinator.release(cleanupEnabled: false)
assert(result?.cleanedText == nil, "raw mode has no cleaned value")
assert(result?.finalText == "raw text", "raw mode returns raw final text")
assert(result?.latency.usedRawFallback == false, "disabled cleanup is not fallback")
```

For idle release assert `result == nil`.

- [ ] **Step 2: Run tests and verify protocol/result failures**

Run `./scripts/run-tests.sh`.

Expected: compile errors show the old `Pasting` methods and `LatencySample` return type.

- [ ] **Step 3: Change the protocol and coordinator**

Replace the `Pasting` declaration with:

```swift
public protocol Pasting: Sendable {
    func captureContext() async -> PasteTarget?
    func paste(_ text: String, to target: PasteTarget?) async throws
    func copy(_ text: String) async
}
```

Add this property to `DictationCoordinator`:

```swift
private var activeTarget: PasteTarget?
```

Replace `press()` and `release(cleanupEnabled:)` with:

```swift
public func press() async throws {
    guard !phase.isBusy else { return }
    activeTarget = await paster.captureContext()
    try await transcriber.start()
    transition(to: .listening)
}

public func release(cleanupEnabled: Bool) async throws -> DictationResult? {
    guard phase == .listening else { return nil }
    do {
        let total = ContinuousClock.now
        transition(to: .finalizing)
        let speech = ContinuousClock.now
        let raw = try await transcriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw LocalFlowError.emptyTranscript }
        let speechMS = speech.duration(to: .now).milliseconds

        let rewrite = ContinuousClock.now
        transition(to: cleanupEnabled ? .rewriting : .pasting)
        let output = cleanupEnabled ? await rewriter.rewrite(raw, deadline: .seconds(2)) : raw
        let cleaned = cleanupEnabled && output != raw ? output : nil
        let rewriteMS = cleanupEnabled ? rewrite.duration(to: .now).milliseconds : 0

        let target = activeTarget
        let paste = ContinuousClock.now
        transition(to: .pasting)
        try await paster.paste(output, to: target)
        let sample = LatencySample(
            timestamp: .now,
            speechFinalizationMilliseconds: speechMS,
            rewriteMilliseconds: rewriteMS,
            pasteMilliseconds: paste.duration(to: .now).milliseconds,
            totalMilliseconds: total.duration(to: .now).milliseconds,
            usedRawFallback: cleanupEnabled && cleaned == nil
        )
        activeTarget = nil
        transition(to: .idle)
        return DictationResult(
            rawText: raw,
            cleanedText: cleaned,
            finalText: output,
            latency: sample,
            target: target
        )
    } catch {
        activeTarget = nil
        let localError = error as? LocalFlowError ?? .transcriptionFailed("internal")
        transition(to: .failed(localError))
        throw error
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run `./scripts/run-tests.sh`.

Expected: coordinator tests pass with raw, cleaned, final, target, and idle behavior.

- [ ] **Step 5: Commit the coordinator result**

```bash
git add Sources/LocalFlowCore/DictationCoordinator.swift Tests/LocalFlowCoreTests/DictationCoordinatorTests.swift
git commit -m "feat: return complete dictation results"
```

### Task 3: Restore the original paste target and support Copy

**Files:**
- Modify: `Sources/LocalFlowCore/DictationState.swift`
- Modify: `Sources/LocalFlowPlatform/PasteService.swift`
- Modify: `Tests/LocalFlowPlatformTests/PasteMarkerTests.swift`

- [ ] **Step 1: Add the safe target-unavailable error test**

Add to `NotchHUDStateTests.swift`:

```swift
let unavailableTarget = NotchHUDState.failure(.pasteTargetUnavailable)
assert(unavailableTarget.label == "Copied · target unavailable", "unavailable target has safe recovery copy")
```

- [ ] **Step 2: Run tests and verify red**

Run `./scripts/run-tests.sh`.

Expected: `.pasteTargetUnavailable` does not exist.

- [ ] **Step 3: Add the error and implement target-aware paste**

Add `pasteTargetUnavailable` to `LocalFlowError` in `DictationState.swift`.

Replace `PasteService` public methods with:

```swift
public func captureContext() -> PasteTarget? {
    captureClipboardIfNeeded()
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return PasteTarget(processIdentifier: app.processIdentifier)
}

public func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

public func paste(_ text: String, to target: PasteTarget?) async throws {
    captureClipboardIfNeeded()
    if let target,
       NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            copy(text)
            throw LocalFlowError.pasteTargetUnavailable
        }
        application.activate(options: [])
        try? await Task.sleep(for: .milliseconds(90))
    }

    guard AXIsProcessTrusted() else {
        copy(text)
        throw LocalFlowError.accessibilityDenied
    }

    let marker = UUID().uuidString
    sessionMarker = marker
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString(marker, forType: Self.markerType)

    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    keyDown?.flags = .maskCommand
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    let captured = capturedClipboard
    capturedClipboard = nil
    Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(350))
        await self?.restoreClipboard(marker: marker, captured: captured)
    }
}

private func captureClipboardIfNeeded() {
    guard !hasCapturedClipboard else { return }
    capturedClipboard = NSPasteboard.general.string(forType: .string)
    hasCapturedClipboard = true
}
```

Add `private var hasCapturedClipboard = false` beside `capturedClipboard`. Immediately after copying the captured value into the local `captured` constant inside `paste`, set both `capturedClipboard = nil` and `hasCapturedClipboard = false`; this distinguishes an intentionally captured empty clipboard from no capture session.

Add this safe message to `NotchHUDState.safeMessage`:

```swift
case .pasteTargetUnavailable: "Copied · target unavailable"
```

Update `PasteMarkerTests.swift` to construct `PasteTarget(processIdentifier:)` and verify the public values compile without reading or writing a real transcript fixture.

- [ ] **Step 4: Run platform tests and build**

Run:

```bash
./scripts/run-tests.sh
swift build --disable-sandbox
```

Expected: all tests and the native AppKit target build.

- [ ] **Step 5: Commit focus-safe paste**

```bash
git add Sources/LocalFlowCore/DictationState.swift Sources/LocalFlowCore/NotchHUDState.swift Sources/LocalFlowPlatform/PasteService.swift Tests/LocalFlowCoreTests/NotchHUDStateTests.swift Tests/LocalFlowPlatformTests/PasteMarkerTests.swift
git commit -m "feat: restore transcript paste targets"
```

### Task 4: Model compact, result, and history geometry

**Files:**
- Modify: `Sources/LocalFlowCore/NotchHUDState.swift`
- Modify: `Tests/LocalFlowCoreTests/NotchHUDStateTests.swift`

- [ ] **Step 1: Write failing geometry tests**

Add:

```swift
let compactSize = NotchHUDLayout.size(for: .compact, preferredWidth: 280)
assert(compactSize == NotchHUDSize(width: 170, height: 38), "compact notch is waveform-sized")

let resultSize = NotchHUDLayout.size(for: .result, preferredWidth: 280)
assert(resultSize == NotchHUDSize(width: 520, height: 148), "result expands from preferred width")

let historySize = NotchHUDLayout.size(for: .history, preferredWidth: 280)
assert(historySize == NotchHUDSize(width: 560, height: 360), "history has room for filters and recent strip")

assert(NotchHUDLayout.size(for: .result, preferredWidth: 900).width == 620, "result width is bounded")
assert(NotchHUDLayout.size(for: .history, preferredWidth: 120).width == 500, "history width keeps a usable minimum")
```

- [ ] **Step 2: Run and verify red**

Run `./scripts/run-tests.sh`.

Expected: missing `NotchPresentationMode`, `NotchHUDSize`, and `size(for:preferredWidth:)`.

- [ ] **Step 3: Add deterministic geometry**

Add:

```swift
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
```

Add to `NotchHUDLayout`:

```swift
public static func size(
    for mode: NotchPresentationMode,
    preferredWidth: Double
) -> NotchHUDSize {
    let preferred = clampedWidth(preferredWidth)
    switch mode {
    case .compact:
        return NotchHUDSize(width: 170, height: 38)
    case .result:
        return NotchHUDSize(width: min(max(preferred + 240, 460), 620), height: 148)
    case .history:
        return NotchHUDSize(width: min(max(preferred + 280, 500), 680), height: 360)
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run `./scripts/run-tests.sh`.

Expected: all geometry and existing safe-label tests pass.

- [ ] **Step 5: Commit presentation geometry**

```bash
git add Sources/LocalFlowCore/NotchHUDState.swift Tests/LocalFlowCoreTests/NotchHUDStateTests.swift
git commit -m "feat: model progressive notch geometry"
```

### Task 5: Build the persistent progressive notch UI

**Files:**
- Create: `Sources/LocalFlowApp/ElongatedWaveform.swift`
- Create: `Sources/LocalFlowApp/TranscriptResultView.swift`
- Create: `Sources/LocalFlowApp/TranscriptHistoryView.swift`
- Modify: `Sources/LocalFlowApp/NotchHUDView.swift`

- [ ] **Step 1: Extract the waveform unchanged**

Move `ElongatedWaveform` from `NotchHUDView.swift` into `ElongatedWaveform.swift`. Keep its 30 fps `TimelineView`, three Canvas paths, 65 points, Reduce Motion pause, line widths, and opacity values unchanged. Build immediately:

```bash
swift build --disable-sandbox
```

Expected: build passes with no visual behavior change.

- [ ] **Step 2: Extend the persistent view model**

Replace `NotchHUDViewModel` with:

```swift
@MainActor final class NotchHUDViewModel: ObservableObject {
    @Published var state: NotchHUDState = .hidden
    @Published var mode: NotchPresentationMode = .compact
    @Published var currentResult: DictationResult?
    @Published var history = TranscriptHistory()
    @Published var searchText = ""
    @Published var sourceFilter: TranscriptSourceFilter = .all
    @Published var feedback: String?

    var onModeChange: ((NotchPresentationMode) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?
    var onSearchFocusChange: ((Bool) -> Void)?
    var onCopy: ((TranscriptSelection) -> Void)?

    var filteredResults: [TranscriptSelection] {
        history.filtered(search: searchText, source: sourceFilter, limit: 5)
    }

    func openHistory() {
        mode = .history
        onModeChange?(.history)
    }

    func collapseToResult() {
        mode = currentResult == nil ? .compact : .result
        onModeChange?(mode)
    }

    func selection(for record: DictationResult) -> TranscriptSelection? {
        switch sourceFilter {
        case .all:
            return TranscriptSelection(
                record: record,
                text: record.finalText,
                source: record.cleanedText == nil ? .raw : .cleaned
            )
        case .raw:
            return TranscriptSelection(record: record, text: record.rawText, source: .raw)
        case .cleaned:
            return record.cleanedText.map {
                TranscriptSelection(record: record, text: $0, source: .cleaned)
            }
        }
    }
}
```

- [ ] **Step 3: Create the result view**

Create `TranscriptResultView.swift` with a three-line transcript, Raw/Cleaned badge, latency, and plain Copy/History buttons for the no-editable-target fallback. Every button must call the corresponding view-model closure with a `TranscriptSelection`; the view must use `.buttonStyle(.plain)`, a 44 pt minimum hit target, and accessibility labels containing the selected source.

The body structure is:

```swift
struct TranscriptResultView: View {
    @ObservedObject var model: NotchHUDViewModel

    var body: some View {
        if let result = model.currentResult,
           let selection = model.selection(for: result) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(selection.source.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                    Spacer()
                    Text("\(Int(result.latency.totalMilliseconds.rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(selection.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    action("Copy", systemImage: "doc.on.doc") { model.onCopy?(selection) }
                    Spacer()
                    action("History", systemImage: "clock.arrow.circlepath") { model.openHistory() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func action(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Create the history view**

Create `TranscriptHistoryView.swift` with:

- a visible `TextField("Search transcripts", text: $model.searchText)`;
- three filter buttons generated from `TranscriptSourceFilter.allCases`;
- a vertical `ForEach(model.filteredResults)` capped by the core store at five;
- a horizontal `ScrollView(.horizontal)` over `model.history.recent(limit: 10)`;
- Copy buttons on every row/card;
- an Escape keyboard shortcut on the collapse button;
- `.onHover { model.onInteractionChange?($0) }`.

Declare `@FocusState private var searchFocused: Bool`, apply `.focused($searchFocused)` to the search field, and add:

```swift
.onChange(of: searchFocused) { _, focused in
    model.onSearchFocusChange?(focused)
}
```

Use this exact filtering binding:

```swift
ForEach(TranscriptSourceFilter.allCases, id: \.self) { filter in
    Button(filter.rawValue) { model.sourceFilter = filter }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            model.sourceFilter == filter ? Color.red.opacity(0.24) : Color.white.opacity(0.07),
            in: Capsule()
        )
        .accessibilityAddTraits(model.sourceFilter == filter ? .isSelected : [])
}
```

- [ ] **Step 5: Make `NotchHUDView` switch modes**

The root view must use one `Group` keyed by `model.mode`:

```swift
Group {
    switch model.mode {
    case .compact:
        compactWaveform
    case .result:
        TranscriptResultView(model: model)
    case .history:
        TranscriptHistoryView(model: model)
    }
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
.background(notchShape)
.animation(stateAnimation, value: model.mode)
.onHover { model.onInteractionChange?($0) }
```

`compactWaveform` contains only `ElongatedWaveform`, centered in the available 170 × 38 pt frame. Keep the hidden VoiceOver label derived from `model.state.label`. Use opacity-only transitions when Reduce Motion is enabled.

- [ ] **Step 6: Build the complete SwiftUI target**

Run:

```bash
swift build --disable-sandbox
./scripts/run-tests.sh
```

Expected: all views compile and all core tests pass.

- [ ] **Step 7: Commit the progressive views**

```bash
git add Sources/LocalFlowApp/ElongatedWaveform.swift Sources/LocalFlowApp/TranscriptResultView.swift Sources/LocalFlowApp/TranscriptHistoryView.swift Sources/LocalFlowApp/NotchHUDView.swift
git commit -m "feat: build progressive transcript notch views"
```

### Task 6: Animate panel geometry and interaction behavior

**Files:**
- Modify: `Sources/LocalFlowApp/NotchHUDController.swift`

- [ ] **Step 1: Add an interactive panel subclass**

Add above the controller:

```swift
private final class TranscriptNotchPanel: NSPanel {
    var permitsKey = false
    override var canBecomeKey: Bool { permitsKey }
}
```

Construct `TranscriptNotchPanel` instead of `NSPanel` and type the stored property as `TranscriptNotchPanel`.

- [ ] **Step 2: Wire mode and interaction callbacks**

After panel configuration in `init()`:

```swift
viewModel.onModeChange = { [weak self] mode in self?.apply(mode: mode) }
viewModel.onInteractionChange = { [weak self] active in self?.setInteractionActive(active) }
viewModel.onSearchFocusChange = { [weak self] focused in self?.setSearchFocused(focused) }
```

Add:

```swift
private func apply(mode: NotchPresentationMode) {
    viewModel.mode = mode
    panel.ignoresMouseEvents = mode == .compact
    panel.permitsKey = mode == .history
    let size = NotchHUDLayout.size(for: mode, preferredWidth: preferredWidth)
    reposition(size: size, animated: !reduceMotion)
}

private func setInteractionActive(_ active: Bool) {
    if active {
        dismissalTask?.cancel()
        dismissalTask = nil
    } else if viewModel.mode == .result {
        scheduleResultDismissal()
    }
}

private func setSearchFocused(_ focused: Bool) {
    panel.permitsKey = viewModel.mode == .history && focused
    if focused {
        panel.makeKeyAndOrderFront(nil)
    } else {
        panel.resignKey()
    }
}
```

Update the existing `show(_:)` path so every listening, processing, and failure state sets `viewModel.currentResult = nil` and calls `apply(mode: .compact)` before ordering the panel front. Update `hide()` to resign key, set `panel.permitsKey = false`, and return the view model to `.compact` only after the fade completes.

- [ ] **Step 3: Add result/history controller APIs**

```swift
func presentResult(_ result: DictationResult, history: TranscriptHistory) {
    dismissalTask?.cancel()
    currentState = .success(milliseconds: result.latency.totalMilliseconds)
    viewModel.state = currentState
    viewModel.currentResult = result
    viewModel.history = history
    viewModel.searchText = ""
    viewModel.sourceFilter = .all
    apply(mode: .result)
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    scheduleResultDismissal()
}

func updateHistory(_ history: TranscriptHistory) {
    viewModel.history = history
}

private func scheduleResultDismissal() {
    dismissalTask?.cancel()
    dismissalTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        self?.hide()
    }
}
```

- [ ] **Step 4: Animate size without moving off-screen**

Replace `reposition()` with `reposition(size:animated:)`. Calculate the active screen first, center the requested width, pin the top to `screen.frame.maxY`, and clamp width to `screen.visibleFrame.width - 24`. Animate `panel.animator().setFrame` for 260 ms result transitions and 300 ms history transitions; use `panel.setFrame` under Reduce Motion.

- [ ] **Step 5: Build and commit the controller**

Run `swift build --disable-sandbox` and `./scripts/run-tests.sh`.

Then:

```bash
git add Sources/LocalFlowApp/NotchHUDController.swift
git commit -m "feat: animate interactive notch expansion"
```

### Task 7: Connect AppModel history, Copy, and conditional automatic Paste

**Files:**
- Modify: `Sources/LocalFlowApp/AppModel.swift`

- [ ] **Step 1: Add history state and action handlers**

Add:

```swift
@Published public private(set) var transcriptHistory = TranscriptHistory()
```

At the end of `init()` configure handlers:

```swift
notchHUD.setActions(
    onCopy: { [weak self] selection in self?.copy(selection) }
)
```

Add the corresponding controller method:

```swift
func setActions(onCopy: @escaping (TranscriptSelection) -> Void) {
    viewModel.onCopy = onCopy
}
```

- [ ] **Step 2: Store and present successful releases**

Replace the success portion of `handleRelease()` with:

```swift
guard let result = try await coordinator.release(cleanupEnabled: cleanupEnabled) else { return }
lastLatency = result.latency
latencyReport.samples.append(result.latency)
if latencyReport.samples.count > 20 { latencyReport.samples.removeFirst() }
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
```

- [ ] **Step 3: Implement Copy and retain automatic paste for focused editable targets**

```swift
private func copy(_ selection: TranscriptSelection) {
    Task {
        await pasteService.copy(selection.text)
        notchHUD.showFeedback("Copied")
    }
}

```

Add `showFeedback(_:)` to the controller to set `viewModel.feedback`, clear it after 1.2 seconds, and never log the selected text.

- [ ] **Step 4: Verify no persistence path exists**

Run:

```bash
rg -n "transcriptHistory|DictationResult|rawText|cleanedText|finalText" Sources
```

Expected: transcript values occur only in core in-memory values, AppModel, views, and paste operations. There must be no use in `UserDefaults`, `Codable`, file writes, or `LocalFlowLogger`.

- [ ] **Step 5: Run tests, build, and commit**

```bash
./scripts/run-tests.sh
swift build --disable-sandbox
git add Sources/LocalFlowApp/AppModel.swift Sources/LocalFlowApp/NotchHUDController.swift
git commit -m "feat: connect transcript history actions"
```

### Task 8: Documentation and real-runtime acceptance

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Document the memory-only history**

Add to README’s feature and privacy sections:

```markdown
- Auto-pastes into focused editable targets; otherwise expands into an actionable transcript with Copy.
- Keeps up to ten recent transcripts in memory for the current app session only.

Transcript history is never written to disk and is cleared when LocalFlow quits.
```

Add the `TranscriptHistory` ring and target-restoration flow to `docs/ARCHITECTURE.md`.

- [ ] **Step 2: Run complete verification**

```bash
./scripts/run-tests.sh
./scripts/package-app.sh
plutil -lint dist/LocalFlow.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/LocalFlow.app
git diff --check
```

Expected: all tests pass, packaging succeeds, plist is OK, signature is valid, and diff check is silent.

- [ ] **Step 3: Launch and visually inspect the signed app**

Launch `dist/LocalFlow.app` without resetting TCC. Verify:

1. Listening is a 170 × 38 pt centered waveform.
2. Processing preserves compact geometry.
3. Completion expands to the current transcript automatically.
4. Copy writes exactly the displayed variant.
5. Paste returns to the original app and cursor.
6. History search and All / Raw / Cleaned filters return correct entries.
7. The vertical list stops at five.
8. The horizontal recent strip reaches ten.
9. Hover pauses dismissal.
10. Reduce Motion removes waveform and geometry movement.
11. Restarting LocalFlow clears history.

- [ ] **Step 4: Commit documentation and acceptance-ready code**

```bash
git add README.md docs/ARCHITECTURE.md
git commit -m "docs: explain transcript notch privacy"
```

- [ ] **Step 5: Publish after final verification**

Push the verified branch to `codejunkie99/LocalFlow` only after the local status is clean and the runtime checks above pass:

```bash
git push origin HEAD:main
```

Do not upload a development-signed application binary.
