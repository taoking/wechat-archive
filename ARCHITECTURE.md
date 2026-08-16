# Architecture

## Decision summary

The portable archive is the source of truth. SQLite is an indexed projection that can be rebuilt from NDJSON and metadata; it is never the sole durable copy. The app is local-only and has no network client.

```text
Explicitly selected local source
  → protected best-effort file snapshot (.db + -wal + -shm; quit WeChat first)
  → local key provider / local decryptor
  → versioned adapter and parser
  → normalized Message / Contact / Conversation / MediaAsset
  → Archive v1 (NDJSON + JSON + media + checksums)
  → SQLite index / FTS5
  → HTML, JSON, NDJSON, CSV (DOCX/PDF adapters later)
```

## Modules

- `Sources/Core/Models.swift` contains portable contracts and consistent `ArchiveError` semantics.
- `Archive.swift` owns NDJSON, manifest, media content addressing and verification.
- `SQLiteArchiveIndex.swift` owns migration, transactions, FTS and parameterized SQL only.
- `Import.swift` defines source-neutral providers and batch coordinator.
- `Export.swift` defines independent exporters; no exporter mutates the archive.
- `WeChatSecurity.swift` and `SQLCipherDatabaseDecryptor.swift` contain scoped key providers, SQLCipher raw-key handling and the local decryptor.
- `WeChatDatabase.swift` contains snapshot and Adapter detection boundaries.
- `SQLiteSchemaScanner.swift` owns Phase 2 plain-SQLite, read-only schema inspection, safe identifier quoting, FTS-internal-table recognition, structural classification and schema fingerprints. It never reads database values.
- `SQLiteSchemaReportWriter.swift` writes Phase 2 JSON/Markdown reports with `0700` directories, `0600` files and report-path redaction; it never opens source databases.
- `Sources/App` orchestrates Core services only; it never executes SQL, handles raw SQLCipher APIs or parses database rows directly.

## Data and error contracts

Inputs at the file/provider boundary are treated as untrusted. They are decoded into `Message` models before they enter the index. Database queries bind values rather than concatenating user input. Public methods return values or throw `ArchiveError`; error text is intentionally generic and never includes a key, message body or full user path.

`SearchQuery.limit` is clamped to 1–500. Message source IDs are used for deduplication when available. Records without source IDs use a documented fallback fingerprint of conversation, sender, timestamp, type, content hash and sorted media hashes; this may have rare false positives for genuinely identical messages.

## Concurrency and safety

The index opens with SQLite FULLMUTEX and each import batch is one transaction. Completed batches survive an interruption; a source can be re-imported safely. A snapshot uses SQLite's `-wal` and `-shm` sidecars, owns a `0700` working directory, sets copied files to `0600`, and compares the source file set plus attributes before and after copying. A changed source fails with a close-WeChat-and-retry error rather than silently importing a partial database. These checks are best effort, not proof of one SQLite transaction snapshot; the UI and documentation require WeChat to be fully quit before real imports.

Phase 2 operates only after Phase 1 export. It discovers `.db` files below the user-selected export root, rejects symlinks and path escapes, and opens each file using `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`. It queries `sqlite_master`, PRAGMA metadata and aggregate `COUNT(*)`, using quoted identifiers from schema metadata. No stored database value is selected. Source-relative paths stay local to the UI; reports omit absolute paths and redact wxid-like path components.

## Dependency decision

The first implementation uses macOS Foundation, CryptoKit and SQLite3 directly. GRDB was not selected because this local v1 needs a small, inspectable dependency surface and explicit SQLite FTS5/migration behavior. A future GRDB adoption requires an ADR and must retain Archive v1 compatibility.

## Decision records

See [docs/decisions/ADR-001-portable-archive-source-of-truth.md](docs/decisions/ADR-001-portable-archive-source-of-truth.md) and [docs/decisions/ADR-002-local-only-key-boundary.md](docs/decisions/ADR-002-local-only-key-boundary.md).
