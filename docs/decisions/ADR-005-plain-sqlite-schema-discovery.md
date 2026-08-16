# ADR-005: Inspect Phase 1 SQLite exports without reading database values

## Status

Accepted

## Date

2026-08-17

## Context

Phase 1 produces ordinary SQLite databases from the user-selected local WeChat SQLCipher sources. Before implementing a message adapter, the project needs a repeatable way to identify message, contact, conversation and media schemas across real local exports. The input can contain private messages, names, wxid values, BLOBs and paths under a user account.

## Decision

Phase 2 uses `SQLiteSchemaScanner` to recursively discover regular `.db` files below an explicitly selected plain-export root. It rejects symlinks and files escaping the selected root, and every handle opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`.

The scanner reads only `sqlite_master`, PRAGMA schema metadata and aggregate `COUNT(*)` results. Database identifiers from schema metadata are always double-quoted with embedded quotes escaped. It does not select database values, text samples or BLOBs. FTS virtual and shadow tables are marked as implementation details so they are not mistaken for business message tables.

The report writer emits protected JSON and Markdown reports under the selected root's `SchemaReports/` directory. Directories use `0700` and report files use `0600`. Reports retain only relative paths, redact wxid-like path components, and omit the selected root, database values and SQL diagnostics.

## Consequences

- Future adapters can target a schema fingerprint group rather than reverse engineer every sharded message database independently.
- Classification is intentionally heuristic: `Detected` requires schema evidence, `Likely` may rely on path or weaker signals, and `Unknown` remains a valid result.
- A very large ordinary table still requires a sequential `COUNT(*)`; the scanner provides per-database progress and cancellation checks without loading rows into memory.
- This phase does not parse messages or create portable archive data. That belongs to the next adapter phase.
