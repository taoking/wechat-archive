# ADR-006: Verify one local message-to-media link before building an adapter

## Status

Accepted

## Date

2026-08-17

## Context

Phase 2 identifies likely message and media schemas without selecting any stored values. Before an Archive v1 adapter can claim that a real WeChat message type has a usable media association, the project needs a small, reproducible local validation path. The data involved can contain chat text, names, wxid identifiers, media identifiers, encrypted payload material and private filesystem paths.

## Decision

Phase 3A accepts only user-selected inputs: a Phase 1 plain SQLite root, a message-table candidate from its Phase 2 report, a sample limit of 100, 250 or 500 rows, and a separately selected original WeChat data root for media discovery. The source reader rejects symlinks and path escapes, opens the selected SQLite file using `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`, and keeps the sample in memory only. `SQLiteSourceValue` distinguishes NULL, INTEGER, REAL, TEXT and BLOB; BLOBs retain length and SHA-256 metadata, with an in-memory size bound.

Field mapping and timestamp inference are evidence-based. Raw message type values are reported as observations, not treated as globally stable mappings. XML parsing disables external entity resolution and records only allow-listed structural media metadata. Arbitrary XML attributes, content text and potential key-like attributes are excluded from reports.

The media scanner works only below the separately selected root, rejects symlinks, uses streaming enumeration, can be cancelled and detects standard file magic bytes. It may recognise JPEG/PNG/GIF headers wrapped by a single uniform XOR byte; when an already narrowed candidate is small enough, normalization happens only in memory for ImageIO or MD5 verification. It does not copy, rename, mutate or bulk-hash the media library. The resolver may confirm only an exact relative path, unique media-ID path evidence, a MD5 value after candidate narrowing, or a unique local file backed by an exact MD5 lookup in the exported hardlink mapping database. A filename alone is never sufficient; uncertainty is represented as unresolved.

`MessageDiscoveryReportWriter` creates `.local-analysis/message-discovery.json` and `.md` with directory permission `0700` and file permission `0600`. Its report DTO has no raw source-value property and omits message content, names, wxid, BLOB bytes, media IDs, MD5 values, media filenames and absolute paths. Phase 3A does not write Archive v1, copy media or perform full message export.

## Consequences

- A single verified message/image chain provides concrete evidence for a later, fixture-backed adapter while keeping the privacy surface small.
- Matching intentionally favours false negatives: an unresolved reference remains unresolved rather than guessing from a filename.
- Large source tables and media trees remain bounded by the selected message sample and scanner result cap, but real media scans can still take time; the UI reports progress and provides cancellation.
- Phase 3B must convert only confirmed evidence into an explicit versioned adapter and add tests before producing portable archive records.
