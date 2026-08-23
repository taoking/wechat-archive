# ADR-004: Batch-export matched SQLCipher databases as plain SQLite

## Status

Accepted — 2026-08-17

## Context

The first useful archival milestone is to make a user's already-authorized local
databases inspectable with standard SQLite tools. wx-cli writes an
`all_keys.json` map keyed by database-relative paths, while a database tree can
contain identically named files in different directories. The workflow must not
expose keys, alter source databases, overwrite an existing plaintext export, or
leave plaintext temporary files behind.

## Decision

Read `all_keys.json` only into memory and accept only 64-hex-character values.
Normalize and match each key by its relative path below the explicit database
root; never match by filename alone. Scan regular `.db` files only and ignore
symlinks. Validate matching databases one at a time so an invalid key or active
source does not stop the rest of the batch.

For a validated database, create the protected SQLCipher snapshot and plaintext
staging database under a new `0700` directory inside the selected export root.
Verify both the SQLite header and a normal read-only SQLite query, then rename
the plaintext database atomically to its corresponding relative output path.
Export roots and created subdirectories use `0700`, files use `0600`, and any
pre-existing destination is skipped. The export result discards its in-memory
key before returning to the UI.

## Alternatives considered

- Match only by database filename: unsafe because different relative paths can
  share a filename and receive the wrong key.
- Decrypt directly into the final destination: exposes partially written output
  after a failed validation and cannot guarantee an atomic handoff.
- Stage in the system temporary directory: a final move to an external volume
  could become a non-atomic copy.
- Write keys to Keychain or an export manifest: outside this phase and creates
  persistence that is unnecessary for a single export session.

## Consequences

Users must fully quit WeChat before scanning and validating. Re-exporting after
a completed batch requires another scan and validation because keys are not
retained. This phase intentionally exports only plain SQLite databases; it does
not parse messages, contacts, media, or schemas.
