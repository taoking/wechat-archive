# ADR-002: Keep database keys local, explicit and short-lived

## Status

Accepted — 2026-08-16

## Context

Database keys and messages are highly sensitive. The application is for a user’s own local data, not remote collection or background discovery.

## Decision

Keys enter through explicit local providers only. Manual entry is one-use and non-persistent by default. Any future persistent key choice uses macOS Keychain only after separate opt-in. The decryptor interface receives the key only for local validation/decryption and has no network path.

## Alternatives considered

- Saving a key in UserDefaults/JSON: easy to implement but unnecessarily exposes a sensitive secret.
- Implicit background key discovery: violates user intent and makes data access opaque.
- Remote decryption service: violates the local-first requirement.

## Consequences

SQLCipher integration must be injected locally and audited. Error and logging policies remain deliberately generic, and tests use artificial keys only when a provider’s format must be tested.
