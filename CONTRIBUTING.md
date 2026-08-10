# Contributing to LocalFlow

LocalFlow is deliberately small: a native menu-bar application, a deterministic core, and thin Apple-platform adapters. Contributions should preserve that shape.

## Development setup

1. Use an Apple silicon Mac running macOS 26 or newer.
2. Install Xcode 26 or compatible Swift 6.2 command-line tools.
3. Clone the repository and run:

   ```bash
   ./scripts/run-tests.sh
   swift build --disable-sandbox
   ```

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add deterministic tests for core state, deadlines, or privacy policies.
- Never add network transcription, transcript logging, or persisted audio.
- Avoid placing transcript content in errors, analytics, fixtures, or screenshots.
- Run `./scripts/run-tests.sh`, `./scripts/package-app.sh`, and `git diff --check` before opening a pull request.

## Style

- Prefer platform APIs and Swift concurrency over third-party dependencies.
- Keep UI state explicit and isolate AppKit bridging from SwiftUI views.
- Respect Reduce Motion and VoiceOver labels for new interface elements.
- Keep the notch compact, nonactivating, and safe for the user’s focused app.

By contributing, you agree that your changes may be distributed under the MIT License.
