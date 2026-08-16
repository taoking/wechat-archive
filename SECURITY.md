# Security

## Threat model

Assets include private messages, media, local database files and database keys. Trust boundaries are file selection, imported JSON/NDJSON, database schema inspection and locally supplied key material. The application has no remote service boundary by design.

## Controls implemented

- User-provided filenames never determine archive directory identifiers.
- Media is content-addressed by SHA-256 rather than filename.
- SQLite values are prepared and bound; search text is never concatenated into SQL.
- HTML export escapes text and attributes; it does not inject message content into raw markup.
- Verification reports paths and failure classes, not message bodies, keys or full source paths.
- Key providers are explicit and local. `ManualKeyProvider` consumes its in-memory value after retrieval.
- Snapshotting includes SQLite WAL/SHM and fails if attributes change while copying.
- `.gitignore` excludes databases, keys, archives, media, decrypted files and local environment files.

## Key limitations

Swift `Data` is not a guaranteed secure-memory primitive. Providers minimize lifetime and copies, but a production SQLCipher integration should review its own secure-memory and process-dump exposure. Do not log keys or pass them to diagnostics.

The included decryptor intentionally returns `Database decryption failed`; it does not implement SQLCipher. A future implementation must be local, audited, read-only against the original source and have artificial fixture tests. It must never shell out with a key in arguments or write plaintext keys to disk.

## Secure development requirements

- Do not add network calls to Core without explicit authorization and a privacy review.
- Validate source file size/type and decoded shape at each import provider boundary.
- Keep source databases read-only and process copies only in a dedicated temporary directory.
- Keep all normal errors generic. Never include a raw SQL error that could embed private input.
- Do not commit realistic chat data, media, database snapshots, test accounts or secrets.
