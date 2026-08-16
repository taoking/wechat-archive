# WeChat Database Integration

## Status

This repository ships `SQLCipherDatabaseDecryptor` for user-provided, 64-character hexadecimal SQLCipher raw keys. It dynamically loads the locally installed SQLCipher runtime (`brew install sqlcipher` / `brew bundle`), so the runtime is not copied into the repository. No real user database or key is included in the repository.

The decryptor has synthetic end-to-end coverage for correct-key validation, wrong-key rejection, protected plaintext export and source immutability. It does not claim compatibility with a specific released WeChat database build; parsing remains adapter-gated.

## Supported pathway today

1. User explicitly selects a local database they are authorized to access.
2. `DatabaseSnapshotter` copies the database plus optional `database-wal` and `database-shm` sidecars into a newly created `0700` working directory; copied files are set to `0600`.
3. A `WeChatKeyProvider` supplies local key material to `SQLCipherDatabaseDecryptor`.
4. `WeChatDatabaseDetector` selects a versioned Adapter using tables, columns and metadata.
5. The Adapter emits normalized values for the archive pipeline.

The snapshotter compares the source file set, size and modification time before and after copying. If a database, `-wal` or `-shm` file changes (or appears/disappears) while copying, it fails with a close-WeChat-and-retry message and removes only its own working directory. This is a protected, best-effort stable file snapshot, not a transaction-consistent SQLite backup. **Completely quit WeChat before validating a key or importing a real database.** Original source files and their sidecars are never modified or cleaned up.

## Key providers

- `ManualKeyProvider`: user enters a hexadecimal key; the provider returns it once and releases its stored copy.
- `LocalKeyFileProvider`: reads a small, explicitly selected local key file. It never creates such a file.
- `EnvironmentKeyProvider`: developer/automation-only opt-in through an environment variable; never log or commit it.
- `KeychainKeyProvider`: reads an explicit account entry from macOS Keychain. A future writer must require a distinct “Remember this key” consent action.

None persists a key in UserDefaults, plist, JSON, SQLite, project files or logs.

## Adapter detection

`WeChatMacV3Adapter` and `WeChatMacV4Adapter` presently model recognizers only. V3 checks a `Message` table with `MsgSvrID`, `CreateTime` and `StrContent`; V4 checks a `message` table with `local_id`, `timestamp` and `payload`. These are deliberately conservative placeholders, not a promise of compatibility. Unknown schemas fail with `Unsupported WeChat database version` rather than being force-parsed.

Each production adapter must document: supported application/database version range, required schema evidence, relevant file layout, message mappings, media mappings, unsupported types and fixture provenance. Fixtures must be synthetic.

## Temporary decryption lifecycle

The decrypted database is temporary working data, never the archive output. The decryptor creates a `0700` work directory and marks generated plaintext SQLite artifacts `0600`. If decryption, export, detach or header validation fails, it removes the plaintext database and its `-wal`, `-shm` and `-journal` sidecars. After a successful decryption, the caller must delete those artifacts when parsing ends unless the user explicitly selects “Keep decrypted database copy” behind a clear privacy warning. Never put it in the project directory or commit it.

## Media and message coverage

The normalized model supports text, image, video, voice, file, sticker, link, location, contact, system, reply and unknown. An unsupported source record must retain safe raw/source metadata and become `unknown`; it must not become a misleading `[图片]` placeholder. Voice decoders are separate from storage so unsupported audio remains retained.
