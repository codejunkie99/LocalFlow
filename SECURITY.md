# LocalFlow Security

## Source-release trust

LocalFlow's update path trusts tagged GitHub source releases from the `codejunkie99/LocalFlow` repository. The in-app updater is user-invoked only and:

- reads GitHub release metadata only after the user chooses **Update LocalFlow**;
- requires a `localflow-release.json` manifest with a strict semantic version, a 40- or 64-character lowercase hex commit, and a 64-character lowercase hex SHA-256;
- verifies the downloaded source archive checksum before extraction;
- rejects archive entries that are absolute, contain `..`, use backslashes, or fall outside the single top-level source directory;
- builds the checkout with a clean environment containing only `PATH`, `HOME`, `TMPDIR`, `LOCALFLOW_SIGNING_IDENTITY`, and the validated `LOCALFLOW_VERSION`;
- requires the staged bundle to carry bundle identifier `dev.localflow.app` and the same code requirement as the installed app;
- replaces the app through a minimal helper with a single previous-app rollback copy and automatic restoration on failure.

## Local signing identity

`scripts/setup-localflow.sh` prefers an existing Developer ID Application or Apple Development identity. If none exists, it creates one **LocalFlow Local Signing** self-signed code-signing identity in the current Mac's login keychain. The signing identity is local to that Mac; deleting it can cause macOS to request Accessibility permission again after an update.

## Private history

Transcript history is stored at `~/Library/Application Support/LocalFlow/history.sqlite3` for the current user only:

- Database, WAL, SHM, and backup files are created with mode `0600`; the parent directory uses `0700`.
- Transcript content is never uploaded, transmitted, or written to logs.
- Audio, cleanup prompts, and clipboard contents are never stored.
- The store checkpoints the WAL before updates and migrations and keeps one recoverable backup.
- **Clear History** deletes transcript rows without modifying permissions or settings.

## Permissions

LocalFlow never edits the macOS TCC database. It requests Microphone and Speech Recognition through explicit buttons and opens System Settings for Accessibility. Permission preservation depends on keeping the same bundle identifier (`dev.localflow.app`) and code requirement across updates.

## Responsible disclosure

Security issues should be reported privately through the repository owner's contact details on the GitHub profile. Do not include transcript content or personal dictation data in a report.
