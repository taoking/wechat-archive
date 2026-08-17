# ADR-010: Preserve complete source rows in a private Archive v1

## Status

Superseded by ADR-011

## Date

2026-08-17

## Context

Phase 3A.2 validated a deterministic Type 3 image relationship on local data,
but discovery output is intentionally redacted and bounded. A durable archive
must instead retain enough source information to rebuild a timeline after the
original WeChat databases and media directories are no longer available. It
also must not discard messages whose current type adapters do not understand.

## Decision

Archive v1 is a private, relational SQLite archive with a versioned manifest.
It streams plaintext `Msg_*` rows in source order and writes every source
column into a typed `message_source_values` table. SQLite NULL, integer, real,
text, and BLOB values are retained separately; BLOB bytes are never converted
through text.

Stable source identity is the unique tuple of source database relative path,
source table, and source local-row identifier. This makes imports idempotent
and permits later incremental imports. Conversations keep their stable source
table identity rather than a generated identifier alone. Reconstruction sorts
by source timestamp and source sequence.

The first adapters normalize only text and the already-validated image type;
all other rows are archived as `unknown` with their complete source row.
Image import follows the Phase 3A.2 message-resource chain. Each main, HD, and
thumbnail variant is recorded independently. Existing DAT files are copied
into the private archive and SHA-256 checked even when a decoded rendition is
available. Missing and unsupported variants remain recorded without dropping
their message.

The archive root and directories use mode 0700. SQLite, manifest, reports,
and media files use mode 0600. Source databases and original media are opened
read-only. Aggregate import reports and normal UI state contain no text,
identifiers, filenames, paths, or keys.

## Alternatives Considered

### Save only normalized messages

- Pros: smaller archive and simpler schema.
- Cons: unknown types and parser mistakes become irreversible data loss.
- Rejected: future adapters need the original SQLite values and BLOBs.

### Continue using discovery reports as import input

- Pros: avoids a second database reader.
- Cons: reports are deliberately redacted, bounded, and unsuitable as a
  source of truth.
- Rejected: the importer reads only plaintext SQLite directly.

### Copy the complete account directory

- Pros: preserves every local file without schema work.
- Cons: needlessly copies unrelated private data and makes a focused archive
  difficult to validate or migrate.
- Rejected: Archive v1 preserves only supported message data and linked image
  variants, while retaining source rows for future parsing.

## Consequences

- Re-importing the same source rows produces no duplicate messages.
- A cancelled import retains only fully committed message transactions and is
  marked cancelled in `import_runs`.
- Archive validation checks SQLite integrity, foreign keys, manifest counts,
  and SHA-256 of every referenced raw or decoded media file.
- Video, voice, generic files, stickers, contacts, UI rendering, and search
  remain outside Archive v1.
