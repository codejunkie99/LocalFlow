# Persistent Transcript History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist unlimited, searchable LocalFlow transcript history in a user-private SQLite database while keeping the notch UI bounded to five filtered results and ten recent cards.

**Architecture:** Add an actor-isolated SQLite store in `LocalFlowPlatform`; keep transcript domain models in `LocalFlowCore`; and replace the notch view model's in-memory filtering with asynchronously refreshed query snapshots. `AppModel` owns the store, writes each successful result before presentation, and exposes confirmed clear-history behavior without logging transcript content.

**Tech Stack:** Swift 6.2, Swift concurrency actors, macOS SQLite3/FTS5, SwiftUI, standalone Swift test executables.

---

## File structure

- Create `Sources/LocalFlowPlatform/TranscriptHistoryStore.swift`: SQLite lifecycle, schema, migrations, writes, bounded queries, checkpoint, backup, and clear.
- Create `Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift`: temporary-database persistence and search tests.
- Modify `Sources/LocalFlowCore/TranscriptHistory.swift`: remove the ten-entry storage cap while preserving query helpers used by unit tests and previews.
- Modify `Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift`: assert unlimited insertion and bounded projections.
- Modify `Sources/LocalFlowApp/AppModel.swift`: own the store and coordinate writes/queries/clear.
- Modify `Sources/LocalFlowApp/NotchHUDController.swift`: accept query snapshots rather than a complete history value.
- Modify `Sources/LocalFlowApp/NotchHUDView.swift`: store published query snapshots and issue query-change callbacks.
- Modify `Sources/LocalFlowApp/TranscriptHistoryView.swift`: render store-backed counts and snapshots.
- Modify `Sources/LocalFlowApp/MenuContentView.swift`: confirmed Clear History action.
- Modify `Resources/Info.plist`, `README.md`, `docs/ARCHITECTURE.md`, and `docs/INSTALL.md`: accurately disclose local transcript persistence.

### Task 1: Make the domain history unlimited but projections bounded

**Files:**
- Modify: `Sources/LocalFlowCore/TranscriptHistory.swift`
- Modify: `Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift`

- [ ] **Step 1: Write the failing unlimited-history test**

Add a test that inserts 25 uniquely identified results and asserts:

```swift
var unlimited = TranscriptHistory()
for index in 0..<25 {
    unlimited.insert(makeResult(index: index, cleaned: index.isMultiple(of: 2)))
}
assert(unlimited.entries.count == 25, "history retains every session result")
assert(unlimited.recent(limit: 10).count == 10, "recent projection remains bounded")
assert(unlimited.filtered(search: "", source: .all, limit: 5).count == 5, "filtered projection remains bounded")

let selection = unlimited.filtered(search: "", source: .all, limit: 1)[0]
let snapshot = TranscriptHistorySnapshot(filtered: [selection], recent: [selection], totalCount: 25)
assert(snapshot.totalCount == 25, "snapshot carries the persistent row count")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh`

Expected: `TranscriptHistoryTests` fails because `entries.count` is 10.

- [ ] **Step 3: Remove only the storage cap**

Change `insert` to deduplicate and prepend without truncating:

```swift
public mutating func insert(_ result: DictationResult) {
    entries.removeAll { $0.id == result.id }
    entries.insert(result, at: 0)
}
```

Keep `recent(limit:)` and `filtered(search:source:limit:)` bounded with `prefix(max(0, limit))`. Add the shared query value:

```swift
public struct TranscriptHistorySnapshot: Sendable, Equatable {
    public let filtered: [TranscriptSelection]
    public let recent: [TranscriptSelection]
    public let totalCount: Int

    public init(filtered: [TranscriptSelection], recent: [TranscriptSelection], totalCount: Int) {
        self.filtered = filtered
        self.recent = recent
        self.totalCount = totalCount
    }

    public static let empty = TranscriptHistorySnapshot(filtered: [], recent: [], totalCount: 0)
}
```

- [ ] **Step 4: Run the full test script**

Run: `./scripts/run-tests.sh`

Expected: all standalone suites pass, including the new 25-entry assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowCore/TranscriptHistory.swift Tests/LocalFlowCoreTests/TranscriptHistoryTests.swift
git commit -m "feat: retain unlimited transcript history"
```

### Task 2: Add the SQLite store and schema

**Files:**
- Create: `Sources/LocalFlowPlatform/TranscriptHistoryStore.swift`
- Create: `Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift`

- [ ] **Step 1: Write failing store creation and reopen tests**

Use a unique temporary directory and assert persistence across actor instances:

```swift
let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
let databaseURL = root.appending(path: "history.sqlite3")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let first = try TranscriptHistoryStore(databaseURL: databaseURL)
try await first.insert(makeResult(index: 1, cleaned: true))
try await first.close()

let reopened = try TranscriptHistoryStore(databaseURL: databaseURL)
let recent = try await reopened.recent(limit: 10)
assert(recent.count == 1, "reopen retains transcript")
assert(recent.first?.finalText == "cleaned 1", "reopen retains final text")
```

Also assert file permissions with `FileManager.default.attributesOfItem(atPath:)` and expect POSIX mode `0600`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh`

Expected: compilation fails because `TranscriptHistoryStore` does not exist.

- [ ] **Step 3: Implement actor lifecycle and schema version 1**

Create this public surface:

```swift
public actor TranscriptHistoryStore {
    public init(databaseURL: URL) throws
    public static func liveDatabaseURL(fileManager: FileManager = .default) throws -> URL
    public func insert(_ result: DictationResult) throws
    public func snapshot(search: String, source: TranscriptSourceFilter) throws -> TranscriptHistorySnapshot
    public func recent(limit: Int) throws -> [DictationResult]
    public func count() throws -> Int
    public func clear() throws
    public func checkpointAndBackup(to backupURL: URL) throws
    public func close() throws
}
```

Open SQLite with `SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX`, execute `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`, and migrate in one immediate transaction:

```sql
CREATE TABLE IF NOT EXISTS transcripts (
  id TEXT PRIMARY KEY NOT NULL,
  created_at REAL NOT NULL,
  raw_text TEXT NOT NULL,
  cleaned_text TEXT,
  final_text TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('raw','cleaned')),
  latency_timestamp REAL NOT NULL,
  speech_ms REAL NOT NULL,
  rewrite_ms REAL NOT NULL,
  paste_ms REAL NOT NULL,
  total_ms REAL NOT NULL,
  used_raw_fallback INTEGER NOT NULL CHECK(used_raw_fallback IN (0,1)),
  target_pid INTEGER,
  did_paste INTEGER NOT NULL CHECK(did_paste IN (0,1))
);
CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
  raw_text, cleaned_text, final_text,
  content='transcripts', content_rowid='rowid'
);
CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
  INSERT INTO transcripts_fts(rowid, raw_text, cleaned_text, final_text)
  VALUES (new.rowid, new.raw_text, new.cleaned_text, new.final_text);
END;
CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
  INSERT INTO transcripts_fts(transcripts_fts, rowid, raw_text, cleaned_text, final_text)
  VALUES ('delete', old.rowid, old.raw_text, old.cleaned_text, old.final_text);
END;
CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE ON transcripts BEGIN
  INSERT INTO transcripts_fts(transcripts_fts, rowid, raw_text, cleaned_text, final_text)
  VALUES ('delete', old.rowid, old.raw_text, old.cleaned_text, old.final_text);
  INSERT INTO transcripts_fts(rowid, raw_text, cleaned_text, final_text)
  VALUES (new.rowid, new.raw_text, new.cleaned_text, new.final_text);
END;
PRAGMA user_version = 1;
```

Create the Application Support directory with mode `0700`, create the database, WAL, and SHM files for the current user only, and normalize database mode to `0600` after opening.

- [ ] **Step 4: Implement prepared-statement binding and row decoding**

Use `sqlite3_prepare_v2`, `sqlite3_bind_*`, `SQLITE_TRANSIENT`, `sqlite3_step`, and `sqlite3_finalize`. Define a private `decodeResult(_:)` that reconstructs `LatencySample`, optional `PasteTarget`, and `DictationResult`. Never interpolate transcript strings into SQL.

- [ ] **Step 5: Run tests**

Run: `./scripts/run-tests.sh`

Expected: store creation, permissions, insert, close, and reopen assertions pass; all existing suites remain green.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocalFlowPlatform/TranscriptHistoryStore.swift Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift
git commit -m "feat: persist transcript history in sqlite"
```

### Task 3: Implement unlimited indexed search and bounded snapshots

**Files:**
- Modify: `Sources/LocalFlowPlatform/TranscriptHistoryStore.swift`
- Modify: `Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift`

- [ ] **Step 1: Write failing search, source-filter, dedupe, and limit tests**

Insert 30 mixed raw/cleaned records, insert one UUID twice with changed text, and assert:

```swift
let all = try await store.snapshot(search: "", source: .all)
assert(all.totalCount == 30, "deduped store keeps 30 records")
assert(all.filtered.count == 5, "filtered snapshot is capped at five")
assert(all.recent.count == 10, "recent snapshot is capped at ten")

let raw = try await store.snapshot(search: "alpha", source: .raw)
assert(raw.filtered.allSatisfy { $0.source == .raw }, "raw filter returns raw selections")
assert(raw.filtered.allSatisfy { $0.text.localizedCaseInsensitiveContains("alpha") }, "search matches raw text")

let cleaned = try await store.snapshot(search: "polished", source: .cleaned)
assert(cleaned.filtered.allSatisfy { $0.source == .cleaned }, "cleaned filter excludes nil cleaned text")
```

- [ ] **Step 2: Run tests to verify failure**

Run: `./scripts/run-tests.sh`

Expected: snapshot/search assertions fail until query methods are implemented.

- [ ] **Step 3: Implement safe FTS query construction and snapshot queries**

Normalize search by trimming whitespace, splitting on Unicode whitespace, escaping `"` as `""`, wrapping each token in double quotes, and joining tokens with `AND`. Empty search uses an indexed `ORDER BY created_at DESC LIMIT ?` query. Non-empty search joins `transcripts_fts` by rowid and uses `transcripts_fts MATCH ?` with a bound parameter.

Select text/source as follows:

```sql
CASE WHEN ? = 'raw' THEN raw_text
     WHEN ? = 'cleaned' THEN cleaned_text
     ELSE final_text END AS selected_text,
CASE WHEN ? = 'raw' THEN 'raw'
     WHEN ? = 'cleaned' THEN 'cleaned'
     ELSE source END AS selected_source
```

For `.cleaned`, add `cleaned_text IS NOT NULL`; return five filtered selections, ten recent final selections, and an unbounded total row count.

- [ ] **Step 4: Run tests**

Run: `./scripts/run-tests.sh`

Expected: all search, dedupe, source, and limit assertions pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowPlatform/TranscriptHistoryStore.swift Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift
git commit -m "feat: query unlimited transcript history"
```

### Task 4: Add checkpoint, backup, migration rollback, and clear

**Files:**
- Modify: `Sources/LocalFlowPlatform/TranscriptHistoryStore.swift`
- Modify: `Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift`

- [ ] **Step 1: Write failing backup and clear tests**

After inserting records, call `checkpointAndBackup(to:)`, clear the live store, open the backup with a second store, and assert the backup retains every row while the live store count is zero. Add a test that passes an unwritable backup parent and asserts the live database is unchanged.

- [ ] **Step 2: Run tests to verify failure**

Run: `./scripts/run-tests.sh`

Expected: compile or assertion failure for missing backup/clear behavior.

- [ ] **Step 3: Implement safe backup and clear**

Run `PRAGMA wal_checkpoint(TRUNCATE)` and use the SQLite online backup API (`sqlite3_backup_init`, `sqlite3_backup_step`, `sqlite3_backup_finish`) into a newly created temporary backup file. Apply mode `0600`, fsync by opening with `FileHandle` and calling `synchronize()`, then rename to the requested backup URL. Implement `clear()` in one transaction with:

```sql
DELETE FROM transcripts;
INSERT INTO transcripts_fts(transcripts_fts) VALUES('rebuild');
```

- [ ] **Step 4: Run tests and commit**

Run: `./scripts/run-tests.sh`

Expected: all backup, failure-safety, and clear tests pass.

```bash
git add Sources/LocalFlowPlatform/TranscriptHistoryStore.swift Tests/LocalFlowPlatformTests/TranscriptHistoryStoreTests.swift
git commit -m "feat: back up and clear transcript history"
```

### Task 5: Connect AppModel and the notch to store-backed snapshots

**Files:**
- Modify: `Sources/LocalFlowApp/AppModel.swift`
- Modify: `Sources/LocalFlowApp/NotchHUDController.swift`
- Modify: `Sources/LocalFlowApp/NotchHUDView.swift`
- Modify: `Sources/LocalFlowApp/TranscriptHistoryView.swift`

- [ ] **Step 1: Replace in-memory view-model projections**

In `NotchHUDViewModel`, replace computed `filteredResults` and `recentResults` with:

```swift
@Published private(set) var historySnapshot = TranscriptHistorySnapshot.empty
var onHistoryQueryChange: ((String, TranscriptSourceFilter) -> Void)?

var filteredResults: [TranscriptSelection] { historySnapshot.filtered }
var recentResults: [TranscriptSelection] { historySnapshot.recent }
var historyCount: Int { historySnapshot.totalCount }

func updateHistorySnapshot(_ snapshot: TranscriptHistorySnapshot) {
    historySnapshot = snapshot
}
```

Invoke `onHistoryQueryChange?(searchText, sourceFilter)` from `openHistory()` and from explicit `didSet` hooks that guard against unchanged values.

- [ ] **Step 2: Wire AppModel queries with cancellation**

Create the live store in `AppModel.init` using `TranscriptHistoryStore.liveDatabaseURL()`. Add one `historyQueryTask`; cancel it before each query; fetch the actor snapshot; and update the controller on `MainActor`. On store failure, log only `history_store:<error code>` and show `History unavailable` without transcript text.

In `handleRelease`, replace process-memory insertion with:

```swift
try await historyStore.insert(result)
await refreshHistory(search: "", source: .all)
if !result.didPaste {
    notchHUD.presentResult(result)
}
```

Keep the dictation result usable if persistence fails: show the fallback result and Copy action, but do not claim it was saved.

- [ ] **Step 3: Update controller and history view**

Change controller result presentation to avoid passing a complete `TranscriptHistory`. Add `updateHistorySnapshot(_:)`. In `TranscriptHistoryView`, replace `model.history.entries.isEmpty` with `model.historyCount == 0` and preserve the five-row/ten-card rendering limits.

- [ ] **Step 4: Run tests and build**

Run: `./scripts/run-tests.sh && swift build --disable-sandbox`

Expected: all tests pass and the app target builds without actor-isolation warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowApp
git commit -m "feat: connect persistent transcript snapshots"
```

### Task 6: Add confirmed clear history and accurate privacy copy

**Files:**
- Modify: `Sources/LocalFlowApp/AppModel.swift`
- Modify: `Sources/LocalFlowApp/MenuContentView.swift`
- Modify: `Resources/Info.plist`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/INSTALL.md`

- [ ] **Step 1: Add the Clear History UI with confirmation**

Add `@State private var confirmingClearHistory = false` to `MenuContentView`, a destructive button, and an alert:

```swift
Button("Clear Transcript History", role: .destructive) {
    confirmingClearHistory = true
}
.disabled(model.historyCount == 0)
.alert("Clear transcript history?", isPresented: $confirmingClearHistory) {
    Button("Cancel", role: .cancel) {}
    Button("Clear History", role: .destructive) { model.clearHistory() }
} message: {
    Text("This permanently removes every saved transcript from this Mac. Permissions and settings are unchanged.")
}
```

Expose `historyCount` and `clearHistory()` on `AppModel`; clear through the actor, refresh the snapshot, and report failure without transcript data.

- [ ] **Step 2: Correct privacy disclosures**

Replace `NSSpeechRecognitionUsageDescription` with:

```text
Speech recognition runs entirely on your Mac. Transcript history is stored locally in your user account and can be cleared at any time.
```

Update README/install/architecture docs with the exact Application Support database path, unlimited retention, clear-history action, no audio retention, and no cloud upload.

- [ ] **Step 3: Run verification and package**

Run:

```bash
./scripts/run-tests.sh
swift build --disable-sandbox
./scripts/package-app.sh
plutil -lint dist/LocalFlow.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/LocalFlow.app
git diff --check
```

Expected: all commands exit 0; plist and signature are valid.

- [ ] **Step 4: Runtime acceptance**

Launch the signed app, create at least 12 dictations, quit, relaunch, and confirm all are searchable while the notch shows at most five filtered and ten recent. Clear history, relaunch, and confirm zero rows while permissions and settings remain granted.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalFlowApp Resources/Info.plist README.md docs/ARCHITECTURE.md docs/INSTALL.md
git commit -m "feat: expose persistent history controls"
```
