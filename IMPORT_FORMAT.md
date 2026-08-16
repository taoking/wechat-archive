# Import Formats

`ChatImportProvider` exposes two operations: `preview(at:)` and `messages(at:)`. Providers parse an explicit local URL into normalized `Message` values; persistence belongs to `ImportCoordinator` and `SQLiteArchiveIndex`.

## JSON

The current JSON provider accepts an array of Archive v1 Message JSON objects. It uses the Archive v1 date and snake-case field definitions.

## NDJSON

The current NDJSON provider accepts one Archive v1 Message object per non-empty UTF-8 line. It streams conceptually by lines and does not require one giant `messages.json` file.

## Planned source adapters

- CSV requires an explicit column-mapping screen. Minimum fields are timestamp, conversation, sender, type, content and media path.
- TXT/HTML imports must preserve available source metadata and label unrepresentable data `unknown`; they must not fabricate contacts, media or times.
- WeChat database import is an adapter pipeline after snapshot/decrypt/detect; see [WECHAT_DATABASE.md](WECHAT_DATABASE.md).

## Incremental import

`source_message_id` is used first when available. Without it, the fallback fingerprint combines conversation ID, sender ID, timestamp, type, content SHA-256 and sorted media hashes. This prevents most duplicated reimports but can treat two truly identical, id-less messages as duplicates. The import session records read, inserted and skipped counts so users can audit the result.

## Crash safety

Imports are written in bounded batches (default 1,000 messages) and each index batch is a transaction. A crash leaves completed batches consistent, and rerunning the import does not generate duplicates under the documented strategy.
