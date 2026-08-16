# ADR-001: Make portable files the archive source of truth

## Status

Accepted — 2026-08-16

## Context

Personal chat records need to survive application, database-library and UI changes over decades. A database-only archive risks requiring a particular engine or schema to remain usable; Word/PDF-only exports lose structure and searchability.

## Decision

Archive v1 uses UTF-8 JSON metadata, conversation/year NDJSON message partitions, ordinary media files and SHA-256 checksums. SQLite is a local, versioned index that may be rebuilt from these files.

## Alternatives considered

- SQLite only: excellent query performance but weaker independent portability.
- A single `messages.json`: simple at small size but poor for very large archives and incremental work.
- Word/PDF only: good reading output, unsuitable for lossless structured preservation.

## Consequences

Every importer must preserve enough normalized data to write portable files, and every schema change needs a documented archive migration. Search/index data can be optimized without changing the durable format.
