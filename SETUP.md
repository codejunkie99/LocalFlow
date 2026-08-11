# LocalFlow Setup

LocalFlow is a private, on-device dictation app for Apple silicon Macs. This page is the one-time front door for a new Mac, including a friend's MacBook Air.

## First three commands

```bash
git clone https://github.com/codejunkie99/LocalFlow.git
cd LocalFlow
./scripts/setup-localflow.sh
```

`setup-localflow.sh` checks prerequisites, selects a stable signing identity, builds LocalFlow, installs one canonical copy at `~/Applications/LocalFlow.app`, verifies its signature, and opens it for the one-time permission grants.

## Command Line Tools

LocalFlow needs Apple Command Line Tools (Swift and Git). If they are missing, the setup script opens Apple's installer. When the installer finishes, run the exact same setup command again:

```bash
./scripts/setup-localflow.sh
```

You can verify the tools with:

```bash
xcode-select -p
swift --version
git --version
```

## Stable local signing identity

macOS grants Microphone, Speech Recognition, and Accessibility permissions to a signed application's code requirement. To keep those grants across updates, every LocalFlow build on a Mac must use the same signing identity.

The setup script:

1. Reuses an existing **Developer ID Application** or **Apple Development** identity when one is present.
2. Otherwise creates one **LocalFlow Local Signing** identity in that Mac's login keychain. It is a self-signed code-signing identity used only by LocalFlow.
3. Records the selected identity in `defaults read dev.localflow.app LocalFlowSigningIdentity`.

The identity is local to that Mac. Do not delete the `LocalFlow Local Signing` keychain item; doing so invalidates the signed requirement and macOS may ask for Accessibility again after the next update.

## One-time permissions

On first launch, LocalFlow shows only the permission actions that are still missing:

1. Grant **Microphone** access.
2. Grant **Speech Recognition** access.
3. Open **System Settings → Privacy & Security → Accessibility** and enable LocalFlow.
4. Quit and reopen LocalFlow after changing Accessibility.

## First dictation test

1. Open TextEdit or Notes and place the cursor in a document.
2. Hold <kbd>⌥ Option</kbd> + <kbd>Space</kbd>, speak, and release.
3. The text auto-pastes at the cursor.

If no editable target is focused, LocalFlow shows the transcript with Copy and History instead.

## Update LocalFlow

From the LocalFlow menu, choose **Update LocalFlow**. The app checks the newest tagged GitHub source release only after you click the action; there is no background updater. It verifies the manifest, checksum, and archive, builds with the same stored signing identity, checkpoints and backs up your history, then swaps the app with rollback safety and relaunches.

## Transcript history and privacy

Successful transcripts are stored locally at:

```text
~/Library/Application Support/LocalFlow/history.sqlite3
```

- History is searchable and unlimited; the notch UI shows at most five filtered results and ten recent cards.
- Audio, prompts, and clipboard contents are never stored.
- Transcript content is never uploaded or logged.
- Use **Clear Transcript History** in the LocalFlow menu to permanently delete saved transcripts. Permissions and settings are unchanged.
- Quitting or replacing LocalFlow does not delete the database because it lives outside the app bundle.

## Signing identity recovery

If the stored identity is missing, run setup again before updating:

```bash
./scripts/setup-localflow.sh
```

The script recreates a local signing identity when no Developer ID or Apple Development identity exists. Updating stops with a clear error if the identity is missing or the replacement's code requirement differs.

## Uninstall

```bash
rm -rf ~/Applications/LocalFlow.app
rm -rf ~/Library/Application\ Support/LocalFlow
defaults delete dev.localflow.app 2>/dev/null || true
```

Removing the `LocalFlow Local Signing` keychain item is optional; keep it if you plan to reinstall on the same Mac.

## Notarized DMG

LocalFlow's free setup uses local signing, not Apple notarization. A polished, notarized DMG remains a later distribution layer for when a Developer ID Application certificate is available.
