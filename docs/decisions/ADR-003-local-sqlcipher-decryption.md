# ADR-003: Decrypt local SQLCipher snapshots with user-provided raw keys

## Status

Accepted — 2026-08-16

## Context

The archive needs to process a user’s own encrypted local database without uploading the database or key. A shell-based workflow risks exposing a key in process arguments or saved scripts; opening the original database read-write risks modifying an active WeChat file.

## Decision

Use a locally installed SQLCipher dylib through a narrow dynamic C API. Validate a `64`-hex-character raw key with SQLCipher’s documented `x'…'` representation, without logging or exposing it. Validate only a read-only consistent snapshot. For export, make a second encrypted snapshot inside a `0700` working directory, open only that snapshot read-write, and create a new `0600` plaintext output using `sqlcipher_export`.

## Alternatives considered

- SQLCipher command line: easy to invoke, but increases risk of key leakage through arguments or scripts.
- Opening the original database read-write: could modify a database currently used by WeChat.
- Bundling a SQLCipher binary in Git: increases repository size, update burden and supply-chain responsibility.

## Consequences

Users install SQLCipher with Homebrew or package it through a controlled release pipeline. The source database is never written. The app must remove temporary plaintext output after parsing unless the user explicitly opts to retain it. Adapter detection remains independent of decryption and rejects unknown WeChat schemas.
