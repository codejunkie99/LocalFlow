# Architecture

LocalFlow is a native Swift 6.2 macOS application with three dependency layers.

```text
LocalFlowApp
  SwiftUI menu, AppModel, store-backed transcript history, and notch NSPanel
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
8. `AppModel` writes each successful result to the user-private `TranscriptHistoryStore` before presenting it.
9. Only state transitions and timing values reach `LocalFlowLogger`; transcript content is never logged.

## Notch HUD

`NotchHUDController` owns a borderless status-bar `NSPanel` with one persistent SwiftUI root. Listening, processing, and failures use a 170 × 38 compact presentation; listening and processing render a centered `Canvas` waveform at 30 fps, with a calmer processing signal. Successful dictation auto-pastes when Accessibility reports a focused editable element. Without an editable target, it expands into a result surface with the final Raw/Cleaned variant, timing receipt, and Copy and History controls. History shows five filtered matches plus a separate recent-ten strip; both views are store-backed query snapshots, so the app never loads the full history into memory.

## Persistent transcript history

`TranscriptHistoryStore` is an actor-isolated SQLite store at `~/Library/Application Support/LocalFlow/history.sqlite3`. It creates the database, WAL, and SHM files for the current user with mode `0600` and its parent directory with mode `0700`. The schema is versioned through `PRAGMA user_version` and migrated in one immediate transaction. An FTS5 virtual table indexes raw, cleaned, and final text; search and recent queries are bounded (`LIMIT 5` filtered rows and `LIMIT 10` recent cards) and return the global persistent row count without loading full history.

`AppModel` owns the store. Each successful dictation is inserted before presentation; a persistence failure leaves the result usable with Copy/History but never claims the transcript was saved. **Clear History** runs a confirmed destructive action that deletes transcript rows without touching permissions or settings. Before updates and schema migrations, the store checkpoints the WAL and creates one recoverable backup with the SQLite online backup API. Audio is never stored.

The compact panel ignores mouse events. The result accepts pointer input without becoming key. History is permitted to become key only when its search field needs it. `PasteService` restores the editable process captured at dictation start; if no editable target is available, the transcript surface becomes the privacy-safe fallback.

## Permission and signing model

macOS identifies permission grants using the application’s code requirement. A stable Apple Development signature normally preserves Microphone, Speech Recognition, and Accessibility grants across rebuilds. Ad-hoc signatures change with the executable, so development builds may require Accessibility approval again.

LocalFlow only requests Microphone or Speech Recognition from explicit buttons. Accessibility opens the relevant System Settings pane; the application never edits the TCC database.

## Data retention

| Data | Stored by LocalFlow? | Lifetime |
| --- | --- | --- |
| Microphone audio | No | Current recording only |
| Raw transcript | Local SQLite, user-private | Until cleared |
| Cleaned transcript | Local SQLite, user-private | Until cleared |
| Final transcript | Local SQLite, user-private | Until cleared |
| Clipboard snapshot | No | Current paste attempt only |
| Timing metrics | In process | Last 20 samples |
| State/timing logs | Yes | No transcript content |

`TranscriptHistoryStore` has no network, logging, or upload path. Quitting and replacing LocalFlow does not remove the database because it lives outside the app bundle.

## Setup and updating

`scripts/setup-localflow.sh` is the first-run front door. It checks macOS/Apple silicon/Command Line Tools, selects or creates one stable per-Mac signing identity, builds the release, installs `~/Applications/LocalFlow.app`, verifies the bundle identifier and signature, records the identity in `dev.localflow.app` preferences, and opens the app for one-time permissions. The signing identity is local to the Mac; updates reuse it so permissions survive.

The in-app **Update LocalFlow** action drives `UpdateService`:

1. The user invokes the action; there is no background updater.
2. `UpdateService` reads the newest tagged GitHub release, decodes `localflow-release.json`, and compares semantic versions.
3. It downloads the source archive, verifies the SHA-256, validates every tar entry, and extracts one top-level source directory.
4. It runs the checkout's `scripts/package-app.sh` with the stored signing identity and a clean environment.
5. It compares bundle identifier and designated code requirement between the staged and installed apps, then checkpoints and backs up the history database.
6. `LocalFlowUpdater`, a minimal helper outside the bundle, waits for LocalFlow to quit, swaps `LocalFlow.app` through `.LocalFlow.previous.app`, and relaunches it with a private receipt path. The new app writes a version-and-executable receipt; the helper verifies it before accepting the update. Any verification, replacement, or relaunch failure restores the previous app and database backup.

`scripts/publish-source-release.sh` publishes a tagged source archive plus `localflow-release.json` with no CI dependency. A public notarized DMG remains out of scope until Developer ID credentials exist.
