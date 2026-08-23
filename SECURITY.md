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
- Snapshotting uses SQLite's canonical `database-wal` / `database-shm` names, creates its own `0700` directory, marks copied files `0600`, and fails if the source file set, size or modification time changes while copying.
- `.gitignore` excludes databases, keys, archives, media, decrypted files and local environment files.

## Key limitations

Swift `Data` is not a guaranteed secure-memory primitive. Providers minimize lifetime and copies; the raw-key literal is generated only in-process for SQLCipher and is never passed to a subprocess, file, log, crash report or diagnostics. Do not log keys or pass them to diagnostics.

`SQLCipherDatabaseDecryptor` dynamically loads a locally installed SQLCipher runtime, validates a source snapshot read-only, then creates an encrypted snapshot in a `0700` work directory for export. The temporary plaintext database and any SQLite sidecars are `0600`; a failed export, detach or validation removes `database`, `database-wal`, `database-shm` and `database-journal`. Source files are not opened for writing and are never passed to cleanup. End-to-end tests use random key material and a generated synthetic database only. Never add a shell-out path that places a key in arguments or writes it to disk.

File copying plus before/after attribute checks can detect a changing source but cannot prove a transaction-consistent SQLite snapshot. Users must completely quit WeChat before validating or importing a real database.

## Secure development requirements

- Do not add network calls to Core without explicit authorization and a privacy review.
- Validate source file size/type and decoded shape at each import provider boundary.
- Keep source databases read-only and process copies only in a dedicated temporary directory.
- Keep all normal errors generic. Never include a raw SQL error that could embed private input.
- Do not commit realistic chat data, media, database snapshots, test accounts or secrets.
