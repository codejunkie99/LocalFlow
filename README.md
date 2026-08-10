<p align="center">
  <img src="assets/localflow-logo.svg" alt="LocalFlow" width="680">
</p>

<p align="center">
  Fast, private, on-device dictation for Apple silicon Macs.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/processing-on--device-E33B4B" alt="On-device">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2F3136" alt="MIT License"></a>
</p>

LocalFlow turns speech into polished text at the active cursor without sending audio or transcripts to a cloud service. Hold <kbd>⌥ Option</kbd> + <kbd>Space</kbd>, speak, and release. Apple SpeechTranscriber handles transcription and Apple Foundation Models can clean the result before LocalFlow pastes it into the focused app.

## What it does

- Streams speech recognition locally with Apple SpeechTranscriber.
- Uses Apple Foundation Models for optional two-second smart cleanup.
- Falls back to the raw transcript if cleanup misses its deadline.
- Pastes safely into the currently focused text field.
- Keeps listening and processing in a 170 × 38 waveform-only notch. Dictation auto-pastes into a focused text field; without an editable target, the notch expands with Copy and History.
- Keeps up to ten recent transcripts in memory for the current app session only.
- Supports click-to-start/stop, push-to-talk, Reduce Motion, and a persistent 220–420 pt expanded-HUD width.
- Never persists audio, transcripts, prompts, or clipboard contents.

## Requirements

- Apple silicon Mac (MacBook Air, MacBook Pro, Mac mini, Mac Studio, or iMac)
- macOS 26.0 or newer
- Xcode 26 or the matching Swift 6.2 command-line tools
- Microphone, Speech Recognition, and Accessibility permissions

## Download

The latest packaged build is available as a direct-download DMG for Apple silicon Macs on macOS 26+:

[Download LocalFlow 0.1.0 DMG](https://github.com/codejunkie99/LocalFlow/releases/download/v0.1.0/LocalFlow-0.1.0-arm64.dmg)

1. Open the downloaded DMG.
2. Drag `LocalFlow.app` into your Applications folder.
3. On first launch, right-click `LocalFlow.app` in Finder and choose **Open**, then confirm once.
4. Grant Microphone, Speech Recognition, and Accessibility when prompted.

The app is signed with an Apple Development certificate but is not notarized, so macOS shows a one-time warning on first launch. Right-clicking and choosing **Open** is the supported way to bypass it.

## Quick start

```bash
git clone https://github.com/codejunkie99/LocalFlow.git
cd LocalFlow
./scripts/package-app.sh
open dist/LocalFlow.app
```

The packaging script automatically uses the first installed Apple Development certificate. If none exists, it creates an ad-hoc signed local build and explains the permission trade-off.

For a full first-run walkthrough, see [Installation](docs/INSTALL.md).

## Use

1. Focus a text field in Notes, TextEdit, Safari, Slack, or your editor.
2. Hold <kbd>⌥ Option</kbd> + <kbd>Space</kbd>.
3. Speak naturally.
4. Release the keys to transcribe, optionally clean up, and paste.

A quick tap of the shortcut enables toggle mode: tap once to start and again to stop. You can also use **Start Dictation** in the LocalFlow window.

## Privacy model

- No networking client is linked or used by the application.
- Audio exists only in memory while recording.
- Transcripts and cleanup prompts are never persisted.
- Transcript history is memory-only, never written to disk, and clears when LocalFlow quits.
- Logs contain state and timing information only.
- Clipboard contents are restored after the paste attempt when possible.
- Apple may download system-managed speech and language-model assets.

See [Architecture](docs/ARCHITECTURE.md) for the trust boundaries and data flow.

## Build and test

```bash
swift build --disable-sandbox
./scripts/run-tests.sh
```

Create a release application bundle:

```bash
./scripts/package-app.sh
```

Use a specific signing identity when needed:

```bash
LOCALFLOW_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

Stable signing lets macOS keep the Accessibility grant across rebuilds. An ad-hoc signature is fine for a quick local build, but macOS may ask for Accessibility again after the executable changes.

## Performance target

For 20 warm trials:

- Median total latency: ≤ 1,500 ms
- p95 total latency: ≤ 2,500 ms
- Paste latency: ≤ 100 ms

Use `artifacts/performance/acceptance-template.json` with `scripts/acceptance-stats.sh` to record a local run.

## Project layout

```text
Sources/LocalFlowApp       SwiftUI menu-bar app and notch HUD
Sources/LocalFlowCore      State machine, deadlines, and privacy-safe policies
Sources/LocalFlowPlatform  Apple Speech, Foundation Models, shortcut, and paste adapters
Tests                      Deterministic core and platform checks
scripts                    Build, package, test, and acceptance helpers
```

## Contributing

Bug reports and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before making changes. Security and privacy issues should follow [SECURITY.md](SECURITY.md).

## License

LocalFlow is available under the [MIT License](LICENSE).
