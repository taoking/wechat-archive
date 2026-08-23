# ADR-013: Avatar Recovery and Core Chat Reconstruction

- Status: Accepted
- Date: 2026-08-23

## Context

The archive is a private, one-time, self-contained export. The viewer must
continue to show names, messages, media, and avatars after the original
WeChat data root and plaintext SQLite export are unavailable. Core chat
readability takes priority over expanding parsers for unsupported message
types.

## Research and evidence

The following public repositories were selected as schema and product-design
leads: `r266-tech/wechat-cli`, `jackwener/wx-cli` (and its public fork),
`kclx/WeChatDecrypted`, and `ILoveBingLu/CipherTalk`. During this decision the
remote GitHub endpoints were unavailable, so no remote source or dependency
was used and no third-party code was copied. Local, non-committed research
notes record that limitation.

The locally validated macOS WeChat 4.x plaintext schema provides a direct,
bounded mapping between contact identities and local avatar image buffers:

```
contact.username -> head_image.username -> head_image.image_buffer
```

The contact table also exposes small and large avatar URL metadata. URLs are
not proof of a local file and are not fetched by export or by the viewer.

## Decision

1. Archive schema v4 adds `avatar_assets` and `avatar_owner_links`.
   `contacts` preserves optional small and large avatar URL metadata for a
   future user-initiated download feature, but viewer rendering is local-only.
2. The exporter accepts a local avatar only when an exact contact identity
   joins to the observed `head_image` cache. It accepts only bounded JPEG,
   PNG, GIF, or WebP buffers, rejects symlinked cache databases, and never
   guesses from filenames, hashes, or URL fragments.
3. Avatar files are private archive media under owner-specific directories,
   named by archive IDs rather than source identities. Their dimensions and
   SHA-256 values are recorded and validated.
4. A contact avatar can be linked to a private conversation, group
   conversation, group member, and account as appropriate. Missing evidence
   produces a neutral placeholder; no incorrect avatar is substituted.
5. The archive viewer remains read-only and accepts only an archive root. It
   uses paged conversations, newest-first message loading with older-history
   pagination, local avatar caching, message summaries, image preview, and
   WAV voice playback.
6. Media copying distinguishes raw-copy failure from decoded-copy failure.
   When raw media is successfully written but decoded output cannot be
   written, the raw archive path and hash remain indexed with
   `decodedCopyFailed` status. Silk decoding has a bounded timeout and
   cooperative cancellation.

## Consequences

- A new full export creates a v4 archive. Earlier archives remain readable
  without avatar support.
- The validator checks SQLite integrity, foreign keys, all media and avatar
  hashes, and rejects unreferenced regular files or symlinks beneath `media/`.
- If no trustworthy local avatar cache exists, the archive retains private URL
  metadata when available but renders a placeholder. It does not access the
  network.
- File attachments and low-priority message parsers remain intentionally
  deferred; unknown messages remain losslessly preserved.
