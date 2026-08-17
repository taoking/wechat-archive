# ADR-008: Keep media identifiers as candidates until independently confirmed

## Status

Accepted

## Date

2026-08-17

## Context

Some Type 3 message payloads contain 32-character hexadecimal strings and
fixed-length binary blocks. A shape match alone does not establish that a value
is an image MD5: it may instead be a server identifier, content reference, or
unrelated opaque value. Treating every shape match as an MD5 sends the resolver
to the wrong hardlink record and can make an unsupported chain look like a
missing file.

The discovery flow must remain local-only and bounded. It must also be able to
record useful structural evidence without serializing message content,
identifiers, paths, filenames, or BLOB bytes.

## Decision

Represent extracted values as `CandidateMediaIdentifier` and retain the value
only in memory. Unkeyed 32-character hexadecimal text is named
`hex32Candidate`, not `MD5`.

Upgrade a candidate to `confirmedMD5` only when at least one independent source
of evidence exists:

- an explicit structured `md5` field name;
- a decoded XML or JSON `md5` key;
- a documented structural field meaning;
- an exact hardlink `md5` text-column hit; or
- a verified equality with the bytes of the resolved local media file.

The bounded Type 3 workflow reports aggregate storage, compression, protobuf
wire structure, candidate counts, hardlink hit counts, and optional timestamp
range overlap. These are diagnostic evidence only; timestamp overlap is never a
media association decision. Safe local reports exclude candidate values and all
source payload values.

## Alternatives Considered

### Treat every 32-character hexadecimal string as an MD5

- Pros: minimal implementation.
- Cons: conflates representation with meaning and makes false negative hardlink
  lookups misleading.
- Rejected: the representation does not provide sufficient evidence.

### Compute MD5 for every local media file

- Pros: may eventually find a matching byte sequence.
- Cons: unbounded read cost, unnecessary access to unrelated private files, and
  no proof that the message candidate has MD5 semantics.
- Rejected: conflicts with the local, bounded reverse-engineering phase.

### Persist all extracted values for later analysis

- Pros: convenient comparison across runs.
- Cons: creates a new privacy-sensitive dataset.
- Rejected: values stay in memory; only aggregates are written beneath the
  ignored local-analysis directory.

## Consequences

- Existing consumers can distinguish an unconfirmed candidate from a confirmed
  MD5 instead of silently treating both as the same value.
- Hardlink queries use the `md5` text column only. The integer `md5_hash` index
  is recorded as schema evidence and is not cast to text for matching.
- A zero-hit batch triggers bounded schema inspection for an intermediate media
  metadata table instead of speculative path guessing or whole-directory hash
  calculation.
