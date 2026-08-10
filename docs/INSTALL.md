# Install LocalFlow

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
./scripts/package-app.sh
```

The resulting app is `dist/LocalFlow.app`.

## 3. Launch

```bash
open dist/LocalFlow.app
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
git pull --ff-only
./scripts/package-app.sh
```

An Apple Development identity keeps the permission requirement stable across rebuilds. Without one, an ad-hoc update may need Accessibility approval again.
