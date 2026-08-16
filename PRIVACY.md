# Privacy

## Local first by design

WeChat Archive has no application server. It does not upload messages, media, databases, keys, archive checksums, telemetry, analytics or crash reports. No network integration is required for normal operation.

## Scope of use

Only import data that the current macOS user owns or is authorized to archive. This project must never be used to discover remote accounts, collect other people’s databases or keys, or operate background scans.

## Key handling

Manual keys default to in-memory, one-use `ManualKeyProvider` values. The import screen starts with “Do not persist key” enabled and clears the field after validation. Key providers never return a printable key value and app errors never include key material.

If a user explicitly enables a future “Remember key” action, it must use macOS Keychain. It must not use UserDefaults, plist, JSON, SQLite, project files or regular logs.

## Data locations

The user chooses source and archive locations. The original database is read-only. Decrypted work is temporary and should be deleted at import completion unless the user makes a separate, explicit, privacy-noticed choice to retain it. Archive data itself is private material and should be encrypted at rest through macOS account/disk protections and backed up deliberately.

## Future network features

Any future network feature requires a new privacy review, a separate user opt-in and a disabled-by-default state. It must not be introduced as part of import, search or error reporting.
