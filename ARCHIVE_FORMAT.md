# WeChat Archive Format v1

## Goals

Archive v1 is intentionally made of ordinary directories, UTF-8 JSON/NDJSON, media files, SQLite and SHA-256 checksums. It is readable without WeChat Archive. SQLite is an optional index, not the authoritative store.

## Layout

```text
WeChatArchive/
├── manifest.json
├── account.json
├── contacts.json
├── conversations.json
├── messages/<stable-conversation-id>/<year>.ndjson
├── media/{images,videos,voice,files,stickers,thumbnails}/<sha-prefix>/<sha256>.bin
├── database/archive.sqlite
├── sources/
├── exports/
└── checksums/SHA256SUMS.txt
```

Stable IDs, never display names, form directory names. This permits `/`, emoji and arbitrary Unicode in a user’s display name without path ambiguity. Media content filenames use their SHA-256; MIME type and original-type information live in message metadata.

## Manifest

`manifest.json` is UTF-8 JSON:

```json
{
  "format": "WeChatArchive",
  "version": 1,
  "created_at": "2026-08-16T12:32:15.123Z",
  "updated_at": "2026-08-16T12:32:15.123Z",
  "message_count": 123456,
  "conversation_count": 234,
  "media_count": 45678
}
```

Readers must reject an unknown `format` or major version instead of guessing. Future versions are additive where possible; a v1→v2 migration must leave the original archive intact until verification succeeds.

## Metadata files

`account.json`, `contacts.json` and `conversations.json` are JSON objects or arrays. IDs are strings. Contact display names, historical names and WeChat ID are optional only when the source did not contain them—readers must not infer missing information.

## Messages

Every non-empty UTF-8 line in a `.ndjson` file is one Message object. Messages are partitioned by stable `conversation_id` and the year in `source_timezone`. A reader may stream a file line by line.

```json
{
  "id": "message-id",
  "source_message_id": "source-id-if-available",
  "conversation_id": "conversation-id",
  "timestamp": "2026-08-16T20:32:15.000Z",
  "source_timezone": "Asia/Shanghai",
  "sender": { "id": "wxid_xxx", "display_name": "张三" },
  "type": "text",
  "content": "晚上一起吃饭吗？",
  "reply_to": null,
  "media": [],
  "raw": null
}
```

Supported `type` values are `text`, `image`, `video`, `voice`, `file`, `sticker`, `link`, `location`, `contact`, `system`, `reply` and `unknown`. Unknown messages must retain source fields in the optional `raw` object; readers must not discard them.

`timestamp` is an ISO 8601 instant. `source_timezone` preserves the source-zone meaning so UIs can render and partition consistently.

## Media

Message `media` is an array of objects containing `id`, `path`, `sha256`, optional `mime`, `size` and `category`. `path` is relative to archive root. No binary content is embedded as Base64 in JSON. A content hash identifies one physical object even when multiple messages reference it.

## Checksums and verification

`checksums/SHA256SUMS.txt` contains one line per archive file except itself:

```text
<64-lowercase-hex-sha256>  messages/conversation-id/2026.ndjson
```

Verification checks manifest compatibility, checksum file syntax, file existence, hash equality, NDJSON decoding and referenced media existence. Reports contain relative archive paths only; they must never include a message’s content or a database key.

## SQLite index

`database/archive.sqlite` contains a versioned index with `contacts`, `conversations`, `participants`, `messages`, `media_assets`, `message_media`, `imports` and `archive_metadata`. It may be discarded and recreated from the portable files. Implementations must use migrations rather than deleting a mismatched index.
