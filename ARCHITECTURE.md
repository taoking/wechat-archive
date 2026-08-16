# Architecture

## Decision summary

The portable archive is the source of truth. SQLite is an indexed projection that can be rebuilt from NDJSON and metadata; it is never the sole durable copy. The app is local-only and has no network client.

```text
Explicitly selected local source
  → read-only snapshot (.db + -wal + -shm)
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
- `WeChatSecurity.swift` contains scoped key providers and decryptor protocol.
- `WeChatDatabase.swift` contains snapshot and Adapter detection boundaries.
- `Sources/App` is presentation-only; it does not run SQL or decrypt databases.

## Data and error contracts

Inputs at the file/provider boundary are treated as untrusted. They are decoded into `Message` models before they enter the index. Database queries bind values rather than concatenating user input. Public methods return values or throw `ArchiveError`; error text is intentionally generic and never includes a key, message body or full user path.

`SearchQuery.limit` is clamped to 1–500. Message source IDs are used for deduplication when available. Records without source IDs use a documented fallback fingerprint of conversation, sender, timestamp, type, content hash and sorted media hashes; this may have rare false positives for genuinely identical messages.

## Concurrency and safety

The index opens with SQLite FULLMUTEX and each import batch is one transaction. Completed batches survive an interruption; a source can be re-imported safely. A snapshot includes WAL/SHM and compares source attributes before and after copying. A changed source fails with a close-WeChat-and-retry error rather than silently importing a partial database.

## Dependency decision

The first implementation uses macOS Foundation, CryptoKit and SQLite3 directly. GRDB was not selected because this local v1 needs a small, inspectable dependency surface and explicit SQLite FTS5/migration behavior. A future GRDB adoption requires an ADR and must retain Archive v1 compatibility.

## Decision records

See [docs/decisions/ADR-001-portable-archive-source-of-truth.md](docs/decisions/ADR-001-portable-archive-source-of-truth.md) and [docs/decisions/ADR-002-local-only-key-boundary.md](docs/decisions/ADR-002-local-only-key-boundary.md).
