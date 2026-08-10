# Architecture

LocalFlow is a native Swift 6.2 macOS application with three dependency layers.

```text
LocalFlowApp
  SwiftUI menu, AppModel, memory-only transcript history, and notch NSPanel
        │
        ▼
LocalFlowCore
  Dictation state machine, deadline race, transcript accumulation,
  latency receipts, shortcut gesture policy, and privacy-safe HUD state
        ▲
        │
LocalFlowPlatform
  Apple SpeechTranscriber, Foundation Models, AVAudioEngine,
  global shortcut monitoring, permissions, logging, and cursor paste
```

## Dictation flow

1. Option-Space or the Start Dictation button calls `DictationCoordinator.press()`.
2. `PasteService` captures the clipboard and the frontmost target application without logging either clipboard or transcript content.
3. `AppleSpeechService` streams microphone buffers into `SpeechAnalyzer` and `SpeechTranscriber`.
4. On stop, the coordinator finalizes the transcript.
5. When Smart Cleanup is enabled, `AppleRewriteService` races Foundation Models against a two-second deadline.
6. The raw transcript wins if the cleanup deadline expires.
7. `PasteService` restores a focused editable target for automatic paste and restores the prior clipboard where possible; otherwise it leaves the result copied for the fallback transcript surface.
8. `AppModel` retains up to ten successful results in `TranscriptHistory` for the current process only.
9. Only state transitions and timing values reach `LocalFlowLogger`.

## Notch HUD

`NotchHUDController` owns a borderless status-bar `NSPanel` with one persistent SwiftUI root. Listening, processing, and failures use a 170 × 38 compact presentation; listening and processing render a centered `Canvas` waveform at 30 fps, with a calmer processing signal. Successful dictation auto-pastes when Accessibility reports a focused editable element. Without an editable target, it expands into a result surface with the final Raw/Cleaned variant, timing receipt, and Copy and History controls. History shows five filtered matches plus a separate recent-ten strip.

The compact panel ignores mouse events. The result accepts pointer input without becoming key. History is permitted to become key only when its search field needs it. `PasteService` restores the editable process captured at dictation start; if no editable target is available, the transcript surface becomes the privacy-safe fallback.

## Permission and signing model

macOS identifies permission grants using the application’s code requirement. A stable Apple Development signature normally preserves Microphone, Speech Recognition, and Accessibility grants across rebuilds. Ad-hoc signatures change with the executable, so development builds may require Accessibility approval again.

LocalFlow only requests Microphone or Speech Recognition from explicit buttons. Accessibility opens the relevant System Settings pane; the application never edits the TCC database.

## Data retention

| Data | Stored by LocalFlow? | Lifetime |
| --- | --- | --- |
| Microphone audio | No | Current recording only |
| Raw transcript | In memory only | Current app session; up to ten successful results |
| Cleaned transcript | In memory only | Current app session; up to ten successful results |
| Clipboard snapshot | No | Current paste attempt only |
| Timing metrics | In process | Last 20 samples |
| State/timing logs | Yes | No speech or clipboard content |

`TranscriptHistory` has no disk, defaults, database, restoration, or logging path. Quitting LocalFlow clears it.
