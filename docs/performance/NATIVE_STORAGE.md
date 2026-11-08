# Native library persistence

The Mac app stores its library in `library.sqlite` under the existing study-data root. The default root is `~/Library/Application Support/Scholia/Study`. Document files, OCR/index sidecars, edit-draft recovery files, and the separate practice database keep their existing locations and formats. This is local native storage; there is no hosted account or HTTP service.

## Why this change is needed

The previous `StudyLibraryStore.save` encoded and atomically replaced all of `library.json` for every saved reading position or conversation change. A serial background writer kept this off the main thread, but it still repeated the complete encoding and disk write.

The release baseline in `results/performance/native-storage-before.json` changed one reading-position field per save. Five samples were collected per fixture:

| Fixture | JSON bytes per save | Median save time |
|---|---:|---:|
| 6 courses, 120 documents, 420 materials, 200 messages | 536,941 | 3.99 ms |
| 89 courses, 1,780 documents, 6,230 materials, 200 messages, 20 MB image | 28,283,067 | 93.42 ms |
| 500 courses, 10,000 documents, 35,000 materials, 200 messages | 6,991,795 | 130.73 ms |

These are storage-call measurements on isolated synthetic data, including encoding and writing. They are not UI frame latency or device-independent guarantees. `benchmark-native-storage.swift --legacy` reproduces the former JSON algorithm with the same fixture shape. The targeted-store measurements use the same script without `--legacy`.

## Persistence contract

The database has separate rows for library/navigation metadata, course metadata, documents, material references, thread metadata, and individual messages. Each ordered child collection has an explicit position column. Course and thread payloads exclude their child arrays, so changing a reading position does not encode the catalog or previous image messages. Each row retains the existing Codable representation, including optional fields.

`StudyLibraryStore` owns a locked helper shared by copies of that store value. It has one SQLite connection and its last committed library snapshot. There is no global cache of library roots. Equatable values and shared Array storage let the helper skip unchanged subtrees before encoding; only changed row payloads are encoded. Reordering unchanged rows updates their positions without encoding their contents.

`StudyLibraryWriter` remains a serial, coalescing background writer. One transaction commits every row in a submitted snapshot, including deletions and ordering. The helper replaces its cached snapshot only after `COMMIT` succeeds. A failed save leaves the last committed data and comparison baseline intact, so retry compares against the correct state. Metrics describe the last successful operation, not a failed attempt.

Work counts distinguish encoded payloads from physical storage writes. A reading-position save changes one document payload row plus the transaction's metadata revision. Encoded-byte counts measure the JSON payload passed to SQLite; they do not measure disk bytes, WAL frames, or database-page writes. Deletion counts track explicitly deleted owner rows; SQLite also removes dependent rows through foreign-key cascades.

SQLite uses foreign keys, WAL journaling, `synchronous=FULL`, a five-second busy timeout, an application identifier, and schema `user_version=1`. Reads also use a transaction so metadata and child rows come from the same commit. Each write checks the revision last read by that helper; another process changing the database causes a conflict error instead of overwriting the newer commit. Explicitly loading again accepts the new revision. Export is a consistent read and does not reset a live writer's expected revision.

The root directory scopes the complete library. Canvas origin/user identifiers stay attached to their existing library and course metadata. Different root directories have independent databases even when IDs match. Document and thread IDs reused across different course owners remain separate rows, preserving legacy contents and existing lookup semantics. Duplicate IDs within the same owner are rejected rather than silently merged.

## Migration and failure behavior

On the first open, a version-1 `library.json` is decoded and copied byte-for-byte to `library-v1-backup-<sha256>.json`. The source JSON is left unchanged. Schema creation, row insertion, and migration completion are committed in one transaction. An interrupted migration can be retried using the same verified backup; it does not append duplicate courses or messages.

Once the database is initialized, the JSON file is not imported again. Normal saves do not update it. A malformed, unrecognized, or newer database fails visibly; the app does not fall back to an older JSON copy. Unsupported legacy versions and duplicate IDs likewise leave the original and any backup intact. The app's existing load-error behavior prevents subsequent writes after a failed initial load.

The existing interrupted-answer repair still applies after loading: empty streaming placeholders are removed and partial answers are retained with the interruption notice. Repairs are persisted by the next normal save.

Migration reads the full legacy file once. Startup still reconstructs the complete in-memory library, and comparison still visits changed collections; this change does not claim lazy library loading or constant-time behavior for every operation. A large changed message or thread draft can still require encoding that particular row.

## Verification and portable export

Build the release app, then run the standalone checks against its actual objects:

```sh
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/native-persistence-regressions.swift
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/benchmark-native-storage.swift results/performance/native-storage-after.json
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/benchmark-native-storage.swift results/performance/native-storage-legacy-reproduced.json --legacy
```

The regression checks use copied synthetic version-1 JSON, immutable backup checks, repeated and interrupted migration, actual child-process termination before commit, rollback and retry, restart, conflicts, export, root isolation, schema rejection, child ordering/deletion, and per-row encoding/write counts. They never open the installed app's library.

Export a selected library root explicitly with the same standalone helper:

```sh
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/native-persistence-regressions.swift --export /path/to/Study /path/to/export/library.json
```

The export is a complete version-1 JSON snapshot of the latest committed database. To return to an older app, quit every Scholia process, export the current database with this version, and preserve the entire study directory before changing anything. Keep `library.sqlite` and any `-wal`/`-shm` files together in the recovery copy; place the exported snapshot at the old app's `library.json` path. Do not use the untouched migration source as a current backup: it predates all subsequent saves. Do not copy, move, or replace SQLite sidecars while an app is using the library.
