# ADR-009: Resolve image attachments through message resources and bounded DAT recovery

## Status

Accepted

## Date

2026-08-17

## Context

The first Phase 3A investigation showed that generic 32-character hexadecimal
values embedded in Type 3 payloads did not hit the exported hardlink index.
They therefore could not be assumed to be image MD5 values. The macOS local
data layout also contains a separate `message_resource` relationship and
versioned image DAT files. We need evidence for one image association without
exporting chats, scanning every attachment, calculating bulk hashes, or
persisting sensitive values.

## Decision

For a bounded sample of at most 100 Type 3 messages, use the following
evidence chain:

1. validate that the selected `Msg_<32-hex>` table maps to a `ChatName2Id`
   entry by local MD5 comparison in memory;
2. parameter-bind the message IDs, type (including low-32-bit compatibility),
   and creation time against `MessageResourceInfo`;
3. parse a 32-character hexadecimal *file base* from the documented packed
   payload marker, with a bounded whole-blob fallback;
4. inspect only current, previous, and next month under that single chat's
   `msg/attach/.../Img` directory for main, HD, and thumbnail DAT variants;
5. detect DAT version before decoding; and
6. for V2, derive candidate keys only from existing macOS kvcomm
   `key_<number>_*.statistic` filenames and raw/normalized account directory
   identifiers, then accept a candidate only after it produces a recognized
   image header.

The V1 fixed-key and V2 AES-ECB/PKCS#7 plus XOR-tail formats are implemented
as a clean-room Swift decoder using CommonCrypto. Decoded bytes and key
material stay in memory. The only persisted Phase 3A.2 artifact is a
privacy-safe local status report beneath ignored `.local-analysis/`, with a
0700 directory and 0600 files.

Publicly available `wx-cli` behaviour was used as an Apache-2.0 reference for
interoperability. No third-party source code was copied. GPL-licensed projects
were not used as implementation sources.

## Alternatives Considered

### Treat generic payload hex as hardlink MD5

- Pros: a short implementation path.
- Cons: the observed zero-hit evidence contradicts this semantic assumption.
- Rejected: a shape match alone is not a media relationship.

### Recursively scan and hash all attachments

- Pros: can eventually find byte-level matches.
- Cons: broad private-data access, high cost, and no proof that a message value
  names the found file.
- Rejected: the resource relationship supplies a narrower, auditable chain.

### Brute-force image keys

- Pros: may recover a file in some cases.
- Cons: uncontrolled computation and an unjustified security boundary.
- Rejected: only key codes present in local kvcomm metadata may be tried.

### Persist decoded images or identifiers for inspection

- Pros: convenient manual debugging.
- Cons: creates a new sensitive dataset outside the user's source data.
- Rejected: output stays structural and decoded data stays in memory.

## Consequences

- A verified image requires both the message-resource relation and an actual
  recognized decoded image; Type 3 is not classified as image solely by raw
  type.
- UI and reports expose only diagnostics and structural status, never file
  bases, filenames, paths, IDs, keys, or decoded media.
- The resolver stops after the first verified image and does not become a
  full-archive or bulk-media-export workflow.
- Missing resource rows, packed data, deterministic paths, DAT format, key
  candidates, rejected keys, and decode failures remain separately diagnosable.
