# ADR-012: Keep Silk decoding behind a reviewed external decoder boundary

## Status

Accepted

## Date

2026-08-22

## Context

Archive v2 preserves observed WeChat Silk voice data byte-for-byte but macOS
does not natively play it. The archive must retain raw Silk even if conversion
cannot run, while successful exports should include portable WAV for the
read-only Viewer.

The reviewed `kn007/silk-v3-decoder` project is MIT licensed. Its included
Skype Silk SDK headers carry a BSD-style redistribution license. The project
is a large C codec distribution, so copying it into the Swift Core without a
complete source and build audit would add a significant maintenance and supply
chain boundary. GPL-only Silk wrappers were rejected.

## Decision

Define the `VoiceDecoder` protocol and a `WAVWriter` in Core. The initial
`SilkProcessVoiceDecoder` invokes an explicitly installed or app-bundled
`silk_v3_decoder` executable using protected temporary files and fixed,
non-shell arguments. It validates Silk before invocation, accepts only a
regular non-symlink executable, bounds PCM output, and never logs source audio
or decoder output.

If no compatible executable is available, the importer still archives raw
Silk and records `decodeUnsupported`; it never drops the message. A successful
decoder result is converted to signed 16-bit little-endian WAV and stored in
the private archive together with the raw Silk.

No third-party codec source or binary is distributed by this repository in
this phase. `THIRD_PARTY_NOTICES.md` records the optional decoder attribution;
a future bundled decoder must preserve the full MIT project notice and the
Skype BSD-style notice, then replace this ADR with the exact build-source
decision.

## Alternatives Considered

### Copy a GPL Silk wrapper into Core

- Pros: one-step integration.
- Cons: incompatible distribution obligations.
- Rejected: the project must not import GPL codec code without an explicit
  license strategy.

### Invoke arbitrary `ffmpeg`

- Pros: commonly installed.
- Cons: the local FFmpeg build does not expose a Silk decoder, and arbitrary
  PATH resolution is not a reliable or auditable codec boundary.
- Rejected: it cannot decode the observed source data by itself.

### Bundle the full C SDK now

- Pros: no external executable requirement.
- Cons: large source import needs a full source/build/license audit.
- Deferred: keep the Swift archive contract stable while that work is reviewed.

## Consequences

- Voice playback works when a compatible approved decoder is present.
- Raw Silk remains the lossless source of truth in every outcome.
- Viewer playback uses only archived WAV and never returns to WeChat data.
