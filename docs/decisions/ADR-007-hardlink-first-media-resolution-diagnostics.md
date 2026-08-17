# ADR-007: Prefer exact hardlink lookup and preserve media-resolution diagnostics

## Status

Accepted

## Date

2026-08-17

## Context

Phase 3A can extract a structural MD5 from a bounded message sample and has an exported plain `hardlink/hardlink.db`. A recursive account-root scan is comparatively broad: the account's `msg` hierarchy can contain many opaque files, and path classification alone may reach its bounded result cap before a relevant candidate is observed. Treating mapping failures, unsupported schemas and missing files as one generic unresolved result makes local validation impossible to audit.

## Decision

For references with a structural 32-hex MD5, Phase 3A first opens the exported hardlink database read-only, discovers compatible mapping tables from their actual schema, and performs a parameter-bound exact lookup. A unique mapping is tested against a small set of account-root-relative path patterns (`<mapping>`, `msg/<mapping>`, `resource/<mapping>`, `cache/<mapping>`). The resulting file is inspected directly without a media-tree scan or a bulk hash.

The diagnostic result is privacy-safe and explicit: missing database, unsupported schema, query failure, no mapping, multiple mappings, missing/ambiguous mapped file, bounded fallback scan, unsupported media decode, or resolved. Reports and UI may show only these labels and structural format metadata; they never write mapping values, MD5 values, filenames or absolute paths.

The existing bounded recursive scanner remains a fallback for unresolved references. Its `20,000` candidate bound is retained, and a reached bound is recorded as `mediaScanTruncated` rather than hidden.

## Consequences

- Exact hardlink evidence takes precedence over path-name guessing and avoids a full-account MD5 pass.
- A local failure identifies the precise evidence-chain step that needs investigation.
- An unrecognized mapped image stays unresolved with `mediaDecodeUnsupported`; Phase 3A does not invent an image decoder or modify the source file.
- The fixed-prefix path rules are intentionally narrow. A future verified storage layout requires a new rule and fixture coverage, not a broad recursive fallback promoted to proof.
