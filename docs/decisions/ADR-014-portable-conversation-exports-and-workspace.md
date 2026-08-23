# ADR-014: Portable Conversation Exports and Persisted Workspace

- Status: Accepted
- Date: 2026-08-23

## Context

An archive is useful for long-term personal viewing, but a person also needs a
small, shareable, offline representation of one selected conversation. The
export must continue to work after the original WeChat directories, plaintext
SQLite databases, and decryption material are unavailable.

The app should also make routine archive viewing practical without retaining
any encryption keys or message content in application preferences.

## Decision

1. Conversation export opens only a `WeChatArchive` root and one archive
   conversation identifier. Its public API has no source-root, SQLCipher, or
   key parameters.
2. HTML, JSON, and Markdown exports are derived data. Each starts in a private
   staging directory and is atomically renamed only after it is complete.
   Cancelling or failing removes the staging directory.
3. HTML has embedded CSS and only relative local media references. It uses no
   remote CSS, JavaScript, CDN, avatar download, or network dependency.
4. Exports include only viewer-friendly decoded images, playable video, WAV
   voice, and locally archived avatars. Raw DAT and Silk stay in the private
   archive rather than becoming normal sharing output.
5. Default output omits source database paths, tables, row identifiers, source
   identities, file-base values, and raw types. An explicit technical option
   may expose only the raw type for diagnostics; it does not expose source
   identities.
6. Archive-relative media is resolved through the viewer's safe resolver and
   copied only after a regular-file, non-symlink check. The export destination
   cannot be inside the archive. Output directories use `0700`; files use
   `0600`.
7. Exporting streams paged archive messages and incrementally writes output;
   it does not build a conversation-wide message array.
8. UserDefaults stores only selected folder locations, recent archive roots,
   the last export format, and the selected conversation. It never stores
   source keys, AES material, passwords, or message content. On launch, only
   a previously valid archive may be reopened automatically; export remains a
   user action.

## Alternatives considered

### Re-read WeChat during each conversation export

Rejected because it would make exports depend on source data, decryption keys,
and the original application installation. It would also weaken the archive's
independence guarantee.

### Export one self-contained HTML document with base64 media

Rejected because large videos and images create huge memory use and browser
files that are difficult to inspect. A small HTML file plus relative media is
portable while remaining streamable.

### Persist every recent source and key setting

Rejected because keys are unnecessary for viewing an archive and retaining
them would violate the application's privacy boundary.

## Consequences

- The same read-only paged viewer database supports both the viewer and the
  exporter, including deterministic time-line ordering and media selection.
- New v4 archives include a conversation timeline index. Older v4 archives
  remain readable without modification.
- Sharing remains a user decision: generated exports contain private content
  and are protected locally by default permissions.
