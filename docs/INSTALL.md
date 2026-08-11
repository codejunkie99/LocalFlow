# Install LocalFlow

For the supported one-time setup on a new Mac, start at [SETUP.md](../SETUP.md). It installs one canonical signed copy at `~/Applications/LocalFlow.app` and guides you through permissions and updates.

## 1. Check the Mac

LocalFlow requires an Apple silicon Mac running macOS 26 or newer. In Terminal:

```bash
uname -m
sw_vers -productVersion
swift --version
```

The architecture should be `arm64`, and Swift should be 6.2 or newer.

## 2. Clone and package

```bash
git clone https://github.com/codejunkie99/LocalFlow.git
cd LocalFlow
./scripts/setup-localflow.sh
```

`setup-localflow.sh` selects or creates a stable signing identity, builds the release, installs it at `~/Applications/LocalFlow.app`, verifies the signature, and opens it.

## 3. Launch

```bash
open ~/Applications/LocalFlow.app
```

If macOS blocks an ad-hoc local build, open **System Settings → Privacy & Security**, review the LocalFlow notice, and choose **Open Anyway** only if you built the repository yourself and trust the checkout.

## 4. Grant permissions

LocalFlow shows only the permission actions that are still needed:

1. Grant Microphone access.
2. Grant Speech Recognition access.
3. Open Accessibility settings and enable LocalFlow.

Quit and reopen LocalFlow after changing Accessibility.

## 5. Test without the shortcut

1. Open TextEdit or Notes and place the cursor in a document.
2. Open LocalFlow and click **Start Dictation**.
3. Speak, then click **Stop Dictation**.

Once that works, use Option-Space from any application.

## Updating

```bash
./scripts/setup-localflow.sh
```

For the in-app update, choose **Update LocalFlow** from the LocalFlow menu. It builds the newest tagged GitHub source release with the same signing identity, backs up history, and swaps the app with rollback safety. `setup-localflow.sh` remains the recovery path when the stored identity is missing.

## Transcript history and privacy

Successful transcripts are stored locally at:

```text
~/Library/Application Support/LocalFlow/history.sqlite3
```

The database is outside the app bundle, so restarting or replacing LocalFlow does not delete it. History is searchable and unlimited, while the notch UI always shows at most five filtered results and ten recent cards. Use **Clear Transcript History** in the LocalFlow menu to permanently delete saved transcripts; permissions and settings remain unchanged. Audio is never stored, and transcript content is never uploaded or logged.
