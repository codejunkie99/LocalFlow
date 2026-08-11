# Transcript Notch Design

**Status:** Approved for implementation
**Date:** 2026-08-10

## Objective

Turn LocalFlow’s status-only notch into a progressive transcript surface without making routine dictation visually heavy. Recording and processing stay compact. A finished transcript expands automatically for immediate reuse, while a deeper history view remains one click away.

## Product decisions

- No voice wake phrase or always-listening microphone mode.
- Transcript history was memory-only at design time; it is now persisted in a user-private local SQLite store and cleared through the in-app action.
- Keep at most ten successful transcripts.
- Automatically expand the finished transcript after every successful dictation.
- Search and All / Raw / Cleaned filters apply to the five-result history list.
- A separate horizontal strip exposes the ten most recent transcripts.
- Every visible transcript supports Copy; automatic paste remains part of the dictation pipeline when a text target is focused.
- Paste returns to the application and cursor context captured when dictation started.

## Interaction states

### Hidden

The panel is not visible and consumes no animation work.

### Compact listening

- Approximately 170 × 38 pt.
- Centered elongated waveform only; no status label.
- The panel ignores mouse events and never takes focus.
- Reduce Motion replaces the animation with a static waveform.

### Compact processing

- Same compact geometry to avoid layout movement.
- A calmer centered waveform distinguishes transcription and cleanup from recording.
- Processing stages remain available to VoiceOver even though visible labels are omitted.

### Result expanded

- Approximately 520 × 148 pt, constrained to the active display.
- Opens automatically after a successful transcript.
- Shows up to three lines of the final pasted text.
- Provides Copy and History controls when no editable paste target was captured.
- Displays whether the result is Cleaned or Raw and the measured latency.
- Begins a four-second collapse timer after appearing.
- Hovering, focusing, or interacting pauses the collapse timer.
- Clicking History opens the full history state.

### History expanded

- Approximately 560 × 360 pt, constrained to the active display.
- Header contains text search and All / Raw / Cleaned filter chips.
- The main list shows at most five matching transcripts, newest first.
- A horizontal Recent strip contains up to ten transcript cards.
- Each list row and recent card exposes Copy.
- Clicking outside, pressing Escape, or using the collapse control returns to the compact or hidden state.

### Failure

- Uses the compact failure treatment and privacy-safe message already defined by `NotchHUDState`.
- Never displays transcript fragments in an error.

## Transcript model

Introduce a Sendable in-memory value with:

- stable UUID
- creation date
- raw transcript
- optional cleaned transcript
- text that was pasted
- whether raw fallback was used
- timing receipt

The display source is derived:

- **All:** final pasted text for every result, with a Raw or Cleaned badge.
- **Raw:** raw text for every result.
- **Cleaned:** cleaned text only; results without successful cleanup are excluded.

Search is case-insensitive and matches the text selected by the active source filter. An in-memory history store inserts newest-first, deduplicates by UUID, and truncates to ten entries. It has no encoding, file, database, defaults, restoration, or logging path.

## Data flow

1. Dictation begins and captures the frontmost target application before LocalFlow becomes interactive.
2. SpeechAnalyzer produces the raw transcript.
3. Foundation Models returns cleaned text before the deadline, or the raw fallback wins.
4. `DictationCoordinator` returns a result containing raw text, optional cleaned text, final text, and latency.
5. The existing automatic paste runs against the captured target.
6. `AppModel` inserts the successful result into the in-memory ten-item store.
7. The notch transitions from compact processing to Result expanded.
8. Copy writes the selected variant to the clipboard.
9. History Paste reactivates the captured target application, waits for focus restoration, and invokes the existing paste path.

Transcript content must never be passed to `LocalFlowLogger`, error descriptions, UserDefaults, files, or performance artifacts.

## Window and focus behavior

The current `NSPanel` remains borderless, all-spaces, and status-bar level.

- Compact states keep `ignoresMouseEvents = true` and remain nonactivating.
- Result expanded accepts pointer events but does not take keyboard focus.
- History expanded becomes key only while the search field is active.
- The previously focused application and target process identifier remain separate from LocalFlow’s temporary panel focus.
- Paste first restores that target. If restoration fails, LocalFlow copies the text and reports “Copied — target unavailable” without losing the transcript.

## Animation

- Use one persistent SwiftUI root view and animate state-driven geometry.
- Compact-to-result uses a 260 ms continuous ease-out morph.
- Result-to-history uses a 300 ms restrained spring with no bounce.
- Content fades and shifts no more than 6 pt; it does not scale aggressively.
- Reduce Motion uses opacity-only transitions lasting at most 100 ms.
- Waveform rendering remains capped at 30 fps and stops when hidden.

## Accessibility

- VoiceOver announces Listening, Transcribing, Cleaning up, Pasting, result availability, and failure states.
- Copy controls include transcript position and selected source in their labels.
- Search has a visible label and standard keyboard focus.
- Filter chips expose selected state.
- Escape collapses history; Return activates the focused action.
- Text respects the user’s system font rendering and supports selection where AppKit permits.

## Testing

### Core tests

- History inserts newest-first and caps at ten.
- All / Raw / Cleaned filtering returns correct source text.
- Search is case-insensitive and respects the selected source.
- The five-result list and ten-result strip limits are deterministic.
- History has no encoding or persistence API.
- Compact, result, and history layout dimensions clamp safely.

### Coordinator tests

- Successful release returns raw, optional cleaned, final text, and latency.
- Deadline fallback records no cleaned value and preserves the raw text.
- Failure does not add a history entry.

### Platform and UI verification

- Compact panel never steals focus.
- Result actions are clickable.
- History search can receive focus without losing the saved paste destination.
- History Paste restores the captured application and cursor target.
- Copy works when the target application no longer exists.
- Reduce Motion disables waveform movement and geometry springs.
- Actual runtime is visually checked at compact, result, and history sizes.

## Acceptance criteria

- Listening and processing show a small centered waveform without visible label text.
- A successful dictation automatically reveals the finished transcript.
- The expanded result can be copied or pasted directly.
- History shows five filtered matches and a horizontally scrollable recent-ten strip.
- Search plus All / Raw / Cleaned filters work without disk persistence.
- Quitting and reopening LocalFlow clears history.
- Existing permissions, signing behavior, privacy-safe logs, and automatic cursor paste remain intact.
- All existing tests and the new history/state tests pass.
