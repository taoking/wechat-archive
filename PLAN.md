# WeChat Archive Development Plan

## Phase 1 — Archive foundation (implemented)

- Stable Archive v1 model and JSON/NDJSON serialization.
- Conversation/year NDJSON partitions, SHA-256 media content addressing, manifest and checksums.
- Versioned SQLite schema, parameterized writes, FTS5 search, import history and deterministic incremental deduplication.
- Offline HTML/CSV/JSON/NDJSON exports and archive verification.
- SwiftUI navigation shell and local-only import/key UX.

## Phase 2 — Plain SQLite schema discovery (implemented)

- Recursively discover Phase 1 plain SQLite exports, inspect schemas read-only and produce protected JSON/Markdown reports.
- Classify likely message, contact, conversation, group, media, index and configuration databases from structural signals; group identical schemas by a structure-only SHA-256 fingerprint.
- Do not read database values, parse messages or export chat content.

## Phase 3A — Message & media link discovery (implemented)

- Load Phase 2's structural report and let the user select a real message-table candidate.
- Read at most 500 rows from one selected plain SQLite table, preserve source SQLite storage classes and infer field mapping, timestamp unit and raw type distributions.
- Extract only structural XML/JSON/BLOB evidence, scan a separately selected local media root in a bounded/cancellable way, and verify media links only when evidence is sufficient.
- Write redacted local analysis reports; do not create or modify Archive v1 data.

## Phase 3B — First real message adapter

- Select a confirmed message schema group and implement a minimal, fixture-backed adapter for normalized messages.
- Add JSON/NDJSON archive import UI with preview, progress, cancellation and resumable source copies.
- Add CSV/TXT/HTML adapters with explicit field mapping rather than heuristic loss of data.

## Phase 3 — Archive browser

- Read conversations and contacts from the index with 100–500 item pagination.
- Add chat timeline, jump-to-message, date navigation, media gallery, Quick Look, AVKit and voice decoder interfaces.
- Implement actual dashboard statistics and health UI.

## Phase 4 — Export and lifecycle

- Add media-copy option to HTML export and deterministic export folders.
- Add OpenXML DOCX exporter and year-split PDF exporter.
- Add Archive v1→v2 migration runner, index rebuild tool and backup reminders.

## Non-goals

- No server-side import, remote key discovery, account access, cloud sync or analytics.
- No parsing of data the local macOS user is not authorized to access.
