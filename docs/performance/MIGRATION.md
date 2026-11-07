# Hosted library migration and recovery

Scholia keeps SQLite. Schema version 2 moves the JSON account library into owned rows: library root, ordered courses, ordered documents, reading progress, ordered conversations, composer drafts and ordered messages. Foreign keys cascade only within an authenticated account. Source files, encryption keys, credentials, session tokens, learning store and native/extension libraries remain separate.

Startup migrates unmigrated accounts in one `BEGIN IMMEDIATE` transaction and publishes `PRAGMA user_version=2` only on commit. Every account root is a completion marker. Repeated startup is idempotent. An interruption rolls back the new tables/rows. Malformed legacy data fails startup with its error; repair a copy or restore the backup before retry. A database from a newer schema is refused. `users.library` remains the original migration snapshot, not a live second source of truth.

Before upgrading a deployed service, stop it and copy the entire data directory (including `accounts.sqlite`, any WAL/SHM files, `encryption.key` and `files/`). Start the new build against a **copy**, run the migration tests and validate account/document/draft counts. Then choose the intended data directory explicitly with `SCHOLIA_DATA_DIR`. This implementation does not deploy or touch the user's live library.

Draft saves and page changes use narrow transactions. Message completion upserts only changed rows; append/edit/delete ordering is preserved. Session-only navigation writes only the session navigation record, and repeated identical navigation skips even that write. Unknown/new durable actions default to the full reconciliation path, which compares stored rows and updates only changed entities. A failed transaction leaves the last successful version available; the request fails visibly and another document can continue saving. Owner revisions reject old draft requests after a newer save or clear, preventing canceled drafts from reappearing.

For rollback without keeping post-upgrade edits, stop the service and restore the complete pre-upgrade copy. To preserve successfully saved changes, run the offline exporter:

```sh
node scripts/performance/export-legacy-store.mjs /copied-data/accounts.sqlite /copied-data/legacy.sqlite
```

The output must not exist. The tool uses SQLite's backup API to copy the source, reconstructs current libraries in `users.library` in the output, removes normalized tables and resets its schema version. It never writes the source. Put the exported database into another complete data-directory copy beside the same encryption key and files, and run the previous build against that copy. Do not copy a bare SQLite main file from a running WAL database.

Verification: a copied 89-workspace legacy fixture includes 534 documents, 1,780 materials, 2,670 messages, drafts, source references and attachments. Tests check exact round-trip values/order, repeated migration, failed migration/retry, transaction failure/independent document progress, restart state, one-row draft/progress/message writes and current-data rollback export. No live account data is used.
