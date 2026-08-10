# LocalFlow Stable Setup, Updates, and Persistent History

## Goal

Make LocalFlow easy to install and update without repeatedly losing macOS permissions, settings, or transcript history. The free distribution path must work on the owner's Mac and a second Mac without CI or a paid Developer ID certificate.

## User experience

### First setup

The repository root will contain `SETUP.md` as the single starting point. It will explain that each Mac needs a one-time installation of Apple Command Line Tools and one stable local code-signing identity. The guided command will be:

```bash
./scripts/setup-localflow.sh
```

The setup script will:

1. Check macOS, Apple silicon, Swift, Git, and Command Line Tools.
2. If Command Line Tools are missing, open Apple's installer and give an exact resume command.
3. Prefer an existing Developer ID or Apple Development identity.
4. If neither exists, create and store one LocalFlow-only self-signed code-signing identity in that Mac's login keychain.
5. Build and sign LocalFlow with the selected persistent identity.
6. Install one canonical copy at `~/Applications/LocalFlow.app`.
7. Verify the bundle identifier, signature, designated requirement, and executable before launch.
8. Open LocalFlow and guide the user through the one-time Microphone, Speech Recognition, and Accessibility grants.

`SETUP.md` will state clearly that the signing identity is local to that Mac. It must not be deleted if the user wants permissions to survive later locally built updates.

### Updating

The setup screen and menu will expose an **Update LocalFlow** action. LocalFlow will check GitHub release metadata only after the user invokes the action; there is no background updater.

The updater will:

1. Download the source archive and release manifest for the newest tagged release into a temporary directory.
2. Verify the expected repository, release version, manifest checksum, archive checksum, and absence of path traversal before extraction.
3. Build and sign the replacement with the same keychain identity used by the installed app.
4. Verify that the replacement has bundle identifier `dev.localflow.app` and the same designated requirement as the installed app.
5. Checkpoint and back up the history database.
6. Start a small updater helper outside the app bundle, quit LocalFlow, and replace `~/Applications/LocalFlow.app` using staging and rename operations.
7. Relaunch the new build and retain the previous app as a single rollback copy until the new launch succeeds.
8. Restore the previous app automatically if verification, replacement, or launch fails.

The updater must never reset TCC, delete the installed app before a verified replacement exists, modify another checkout, or upload a transcript.

## Persistent transcript history

Transcript history will move from process memory to a local SQLite database at:

```text
~/Library/Application Support/LocalFlow/history.sqlite3
```

The database is outside the app bundle, so replacing the app cannot remove it. History is unlimited and searchable. Each row stores the transcript identifier, creation date, raw text, optional cleaned text, final text, source, latency receipt, and paste outcome. Audio is never stored.

The storage layer will provide bounded queries for the interface: five filtered rows and ten recent cards remain the current presentation limits even though the database retains all entries. An FTS5 index will support search without loading the full history into memory. SQLite migrations will be versioned and transactional. Before an app update or schema migration, LocalFlow will checkpoint the WAL and keep one recoverable database backup. Database files will be created for the current user only with mode `0600`.

History remains local to the macOS user account. A **Clear History** action will require confirmation and will delete transcript rows without changing permissions or app settings.

## Settings and permissions

Preferences such as Smart Cleanup and notch width remain in the app's existing preferences domain. The canonical bundle identifier remains `dev.localflow.app`.

Permission preservation depends on keeping the same bundle identifier and designated code requirement on a given Mac. Setup records the selected signing identity's stable identifier in LocalFlow's preferences. Updates stop before replacement if that identity is missing or the new designated requirement differs.

No permission request runs automatically during an update. After relaunch, LocalFlow reads the current permission states and shows only actions for permissions that are actually missing.

## DMG distribution

A polished public DMG remains a later distribution layer. When a Developer ID Application certificate is available, the release process can build a hardened, notarized DMG for first installation while retaining the same SQLite store and in-app updater architecture. The free local-signing setup does not claim to be a notarized third-party distribution.

## Components

- `TranscriptHistoryStore`: SQLite schema, migrations, writes, bounded searches, backup, and clear-history operations.
- `UpdateService`: release lookup, archive verification, build orchestration, signing requirement checks, and progress state.
- `LocalFlowUpdater`: minimal helper executable responsible only for verified replacement, rollback, and relaunch.
- `scripts/setup-localflow.sh`: one-time prerequisites, signing identity selection or creation, canonical installation, and verification.
- `SETUP.md`: first-run instructions for the owner and a second Mac.
- Setup UI: update action, progress, version receipt, recoverable errors, and clear-history confirmation.

## Failure handling

- Network or GitHub failure leaves the current app untouched.
- Build or signing failure leaves the current app untouched and explains the missing prerequisite.
- Signature mismatch blocks replacement.
- Database backup or checkpoint failure blocks replacement.
- Failed relaunch or migration restores both the last app bundle and the pre-update database backup.
- Database migration failure reopens the prior database backup and reports a privacy-safe error without logging transcript content.

## Validation

Automated tests will cover history persistence, unlimited insertion, filtered pagination, migration rollback, backup restoration, version comparison, archive validation, signing-identity mismatch, updater state transitions, and rollback decisions.

Runtime acceptance will verify:

1. First setup on a clean macOS user account.
2. Permissions granted once and still granted after an in-place update.
3. Settings and searchable history retained after app restart and update.
4. Failed update leaves the old app launchable.
5. A second Mac can complete `SETUP.md`, update from the app, and preserve its own local signing identity and permissions.

## Non-goals

- Background or silent updating.
- Cloud sync or remote transcript storage.
- Audio retention.
- CI-based release publishing.
- Automatic TCC database modification.
- A notarized public DMG before Developer ID credentials exist.
