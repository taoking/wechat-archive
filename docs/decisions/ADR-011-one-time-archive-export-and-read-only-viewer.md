# ADR-011: Use one-time Archive v2 exports with a read-only viewer

## Status

Accepted

## Date

2026-08-17

## Context

The product scope is a one-time, complete local export that remains usable
after WeChat and its plaintext SQLite export are unavailable. The previous
Archive v1 plan described incremental import semantics and used `local_id` as
the physical source identity. A real SQLite table can contain more than one
row with the same local ID, so that identity can discard history during a
single export. Incremental merge and media repair are explicitly outside this
version's scope.

Bounded local validation confirmed the Type 43 video relationship through the
message resource index and deterministic monthly video path, and the Type 34
voice relationship through `VoiceInfo` and its raw voice BLOB. macOS can play
archived MP4 directly, but it does not natively play the observed Silk data.

## Decision

Archive schema version 2 uses the tuple `(source_database, source_table,
source_sqlite_rowid)` as physical message identity. `local_id` and `server_id`
remain preserved source metadata, not a uniqueness constraint.

Each Full Export requires a new or empty destination. Existing archives are
not merged, repaired, or incrementally updated. Every supported and unknown
message retains its complete typed source row. The unified `media_assets`
table stores image, video, and voice variants with independent hashes and
paths. Videos are copied unchanged as play/raw/thumbnail assets; no transcoder
is introduced. Voice data is copied byte-for-byte and marked Silk only after
its bounded header detector confirms that format. No unreviewed Silk decoder
is bundled, so raw Silk remains viewable as archived-but-not-playable until a
compatible, license-reviewed decoder is selected.

The Archive Viewer opens only `archive.sqlite` in SQLite read-only/query-only
mode and resolves media only below the selected archive folder. Conversation
and timeline queries are paged and join media metadata in the same query,
avoiding source-directory access and N+1 media lookups.

## Alternatives Considered

### Keep `local_id` as the message key

- Pros: familiar field and a smaller key.
- Cons: duplicate local IDs can lose source rows in a full export.
- Rejected: SQLite `rowid` is the physical identity of the exported table.

### Merge into an existing destination

- Pros: apparent convenience for repeated export.
- Cons: requires complete sync, media repair, conflict and cancellation
  semantics that are not in this product version.
- Rejected: a new empty destination makes one-time export deterministic.

### Transcode video or bundle an unreviewed Silk decoder

- Pros: uniform playback formats.
- Cons: transcode changes source bytes; an unreviewed decoder introduces
  licensing and maintenance risk.
- Rejected: preserve original assets first; MP4 plays directly and raw Silk is
  retained for a later audited playback implementation.

## Consequences

- A full export cannot silently omit duplicate-local-ID rows.
- Archive v2 is self-contained for text, images, archived MP4, and archived
  voice bytes; the Viewer does not need a WeChat root or a plaintext export.
- Image and video media missing on the local device remain explicit `missing`
  assets without dropping their message.
- Raw Silk voice preservation is complete, while Silk playback is intentionally
  pending a compatible decoder.
