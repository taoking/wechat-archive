# WeChat Archive Development Plan

## Phase 1 — Archive foundation (implemented)

- Stable Archive v1 model and JSON/NDJSON serialization.
- Conversation/year NDJSON partitions, SHA-256 media content addressing, manifest and checksums.
- Versioned SQLite schema, parameterized writes, FTS5 search, import history and deterministic incremental deduplication.
- Offline HTML/CSV/JSON/NDJSON exports and archive verification.
- SwiftUI navigation shell and local-only import/key UX.

## Phase 2 — Production import adapters

- SQLCipher local decryptor, read-only source snapshot and synthetic end-to-end verification (implemented).
- Implement schema inspection plus each supported WeChat macOS Adapter with artificial fixtures.
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
