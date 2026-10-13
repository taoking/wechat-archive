# Usage Guide

*[中文版本见 USAGE.md](USAGE.md)*

WeChat Archive turns your authorized local Mac WeChat data into a standalone archive for offline browsing, search and conversation export. The latest source includes local database key extraction, SQLCipher validation, decryption and archive creation in one workflow. The desktop app also supports separate steps.

For download choices and a beginner walkthrough, see the [Chinese getting-started guide](docs/getting-started.md). The v0.3.0 Release provides an Apple Silicon App, but **does not include the newly integrated key extraction workflow**. Download the latest main source for that workflow. Source builds require macOS 15+, full Xcode with Swift 6, Python 3.9+ and Homebrew; fresh key extraction also requires Rust. Key extraction has been checked on Apple Silicon with WeChat 4.1.15; Intel and other WeChat versions still need real-device verification.

## Choose Your Starting Point

| What you already have | Next step |
| --- | --- |
| Your account logged into Mac WeChat, no keys | Use the workflow below |
| Matching `all_keys.json` | Reuse it below or use desktop Database Export |
| Plain SQLite export and original account media | Use desktop Full Export |
| A standalone `WeChatArchive` folder | Open it in Archive Viewer; no WeChat or keys needed |

Migration means copying the whole archive to another compatible Mac. It does not import records back into WeChat. No Windows or phone key extraction entry point is provided.

## Environment Setup

1. Install full Xcode (Command Line Tools alone cannot run the SwiftUI app).
2. Install Homebrew dependencies (the SQLCipher runtime, and `zstd`, used to recover some message text):

   ```bash
   brew bundle
   ```

   or:

   ```bash
   brew install sqlcipher zstd
   ```

3. From the project directory, run:

   ```bash
   ./scripts/run-app.sh
   ```

   This script places the Swift executable into a local `.app` bundle before launching it, so macOS correctly activates the window and file picker panels. Don't use a bare `swift run WeChatArchive` for interactive use — it isn't a registered `.app` bundle, and the Open panel may fail to receive keyboard focus.

   You can also open `Package.swift` in Xcode, select the `WeChatArchive` executable, and run it there.

## From Key Extraction to an Archive

Download and extract the latest main source, or clone it with Git. Run all commands from the project folder containing `Package.swift`:

```zsh
git clone https://github.com/taoking/wechat-archive.git
cd wechat-archive
brew bundle
brew install rust
```

If you downloaded the ZIP, enter its extracted folder instead of cloning again. Log into your account in the official WeChat app, then run:

```zsh
./scripts/archive-wechat.command --prepare-copy --open-viewer
```

This explicitly allows stopping the running WeChat and preparing a temporary debugging copy. The official app is not re-signed or replaced. Wait for the copy's login screen, **do not enter WeChat yet**, and press Return in the terminal when asked to arm capture. After the capture prompt, enter WeChat in the copy and complete any phone confirmation or system authorization. Open relevant chats during capture. The default window is 180 seconds; `--capture-seconds 300` extends it to the maximum. Do not run the whole workflow with `sudo`.

The workflow then quits WeChat, snapshots the databases, validates keys, exports plain SQLite, creates and validates the archive, and opens the viewer. Missing keys stop the workflow by default. Only exact database paths explicitly passed with `--allow-missing` can be excluded; such results report incomplete coverage. Invalid keys cannot be excluded.

The archive is under `wechat/archives/<run-id>/`; the result report is `wechat/runs/<run-id>/result.json`. For archive success, check `status`, `completeCoverage`, `archiveCreated`, and the import report. `completed_with_allowed_missing` is not full database coverage. Coverage only describes detected database keys, not absent local media or unsynced phone history. Real chat full archival has not yet received end-to-end acceptance testing; automated end-to-end tests use synthetic data.

Archive mode cleans up the generated temporary keys and plain working databases by default, including on failure; `--keep-keys` / `--keep-databases` explicitly retain them. Encrypted snapshots and incomplete archives may remain. Back up the **entire archive folder**, including media. Private file permissions do not encrypt your backups. See [module details](tools/wechat_keys/README.md) for limitations, options and cleanup.

## Reuse Existing Keys

Fully quit WeChat first, then replace these placeholders with your own absolute paths:

```zsh
./scripts/archive-wechat.command \
  --db-dir "/absolute/path/to/db_storage" \
  --keys "/absolute/path/to/all_keys.json" --open-viewer
```

Use the original account's `db_storage`: its parent supplies media. A database-only snapshot is not an account media root. Your original `--keys` input file is never deleted. To export only keys, run `./scripts/extract-keys.command --prepare-copy`; that mode retains a private `wechat/keys/<run-id>/all_keys.json`.

The following sections describe the desktop steps. Schema and message discovery are advanced diagnostic tools, not mandatory archive creation steps.

## Batch Export to Plain SQLite

1. **Fully quit WeChat.** Don't just close the window — quit from the menu and confirm it isn't still running. This avoids missing WAL data that hasn't been checkpointed yet.
2. Open the app's **Database Export** page.
3. Click **Choose Folder** and select your WeChat `db_storage` root. If the macOS file picker can't navigate into the container directory, type the full absolute path (`~` is supported) on the same line and click **Use Path**; relative paths, plain files, and nonexistent directories are rejected. Once the directory is confirmed, the app detects the default `~/.wx-cli/all_keys.json` but does not read the keys inside it.
4. If the default key map exists, the UI shows "Ready to scan" and you can continue directly; otherwise click "Use `~/.wx-cli/all_keys.json`" or "Choose File" to select the key map.
5. Click **Scan**. The app recursively finds `*.db` files and matches, for example, `contact/contact.db` as a relative path against `all_keys.json` — it never matches by filename alone.
6. Click **Validate All**. Each matched database is validated in turn; a failure on one does not block the others.
7. Click **Choose Export Folder** to select an output directory, then click **Export Databases**.
8. Open the result with any plain SQLite tool, for example:

   ```bash
   sqlite3 /path/to/Export/contact/contact.db '.tables'
   ```

The desktop Database Export page reads `all_keys.json` into memory only; it never copies the keys into exports, logs, databases or Git, or passes key bytes as command-line arguments. After export completes, the app discards matched keys held in the session; to export again, re-scan and re-validate. The separate key extraction workflow explicitly creates a private key JSON as described above.

## Database Structure Discovery (Plain SQLite)

1. Open the app's **Database Structure Discovery** page.
2. Click **Choose Folder** and select the plain SQLite root exported in Phase 1; if the file picker is inconvenient, paste the full absolute path and click **Use Path**.
3. Click **Analyze Databases**. This phase never reads `all_keys.json`, needs no key, and never touches the original SQLCipher databases.
4. The page shows per-database progress and, on completion, summarizes database, table, schema-group, and message/contact/conversation/media candidate counts.
5. Click **Open Report Folder** to view `SchemaReports/` under the selected root:

   ```text
   SchemaReports/
   ├── schema-summary.json
   ├── schema-summary.md
   └── databases/
       └── …-<stable-id>.md
   ```

The scanner only opens ordinary `*.db` files with `SQLITE_OPEN_READONLY`, running schema queries and `COUNT(*)` per database/table — it never loads database contents into memory at once. Reports contain only relative paths, table/column/index/foreign-key names, declared types, constraints, aggregate row counts, classification, and schema fingerprints; they never contain chat text, contact names, wxids, BLOB data, TEXT samples, keys, or your home directory path. FTS virtual tables and shadow tables are identified as index structures, never mistaken for business message tables.

Classification uses path and structural heuristics, so **detected** means structural evidence exists, **likely** means mostly path-based or weaker signals, and **unknown** means insufficient evidence — it is not a definitive claim about database content. Databases with identical structure are grouped by schema fingerprint, giving you a starting point for choosing message/contact/conversation adapters in the next phase.

`SchemaReports/` and its `databases/` subdirectory are set to `0700`; report files are `0600`. Real databases and real reports are excluded via `.gitignore` — never commit them to Git.

## Message and Media Link Verification (Bounded)

1. Complete **Database Structure Discovery** first, confirming `SchemaReports/schema-summary.json` exists under the plain SQLite root.
2. Open **Message Discovery**. Select the same plain SQLite root; the app only reads the Phase 2 report above to list candidate message tables.
3. Choose a candidate message table and a row cap of 100, 250, or 500.
4. Choose your own original WeChat data root. This input is required: the app never scans the whole disk by default or guesses the WeChat directory automatically.
5. Click **Discover Messages and Media**. It opens the selected plain database with `SQLITE_OPEN_READONLY` and reads at most the chosen row count; the media scan only reads file headers and can be stopped via **Cancel**.
6. Review field mapping, time units, raw type distribution, a bounded local preview, and media resolution evidence under **Bounded Local Verification**. The preview is shown only in the current window — it is never written to a report or uploaded.
7. Click **Open Local Analysis Report** to view `.local-analysis/` under the plain SQLite root:

   ```text
   .local-analysis/
   ├── message-discovery.json
   └── message-discovery.md
   ```

Media is only marked resolved when one of these forms of evidence exists: an exact relative path, a uniquely matching media-ID path, an exact MD5 within an already-narrowed candidate set, or a local file uniquely located via the exported hardlink map by exact MD5. The scanner can also identify single-byte XOR-wrapped JPEG/PNG/GIF headers read-only; when needed it recovers their bytes in memory only, to confirm dimensions or an exact MD5, and never modifies the original file. Filename-only matches remain **unresolved**. Reports retain only structure, field names, sample counts, raw type statistics, media format/dimensions/size, and match confidence — never message bodies, names, wxids, BLOBs, media IDs, MD5s, media filenames, or absolute paths. Directory permissions are `0700`; report files are `0600`.

## Archive Export and Archive Viewer

1. After completing the Phase 1 plain SQLite export, open **Full Export**.
2. Select the plain SQLite export root and your own original WeChat account root; both are opened read-only.
3. Select a **new or empty directory** as the archive destination. Full Export never merges, overwrites, or repairs an existing archive; if the directory is non-empty, the export refuses to start.
4. Click **Analyze Export** to view message databases, tables, and an estimated message count. The production entry defaults to **All**; for development verification you can choose 100 or 1,000.
5. Click **Full Export**. Progress shows message classification and media bytes copied; after cancellation, already-completed transactions remain a verifiable archive, but a subsequent full export requires a new empty directory.
6. Open **Archive Viewer** and select the resulting archive folder. The viewer opens its `archive.sqlite` read-only and never reads the WeChat directory, plain SQLite source directory, or any key.

The archive contains `archive.sqlite`, `archive-manifest.json`, `metadata/import-report.json`, and a media directory. Text, recovered images, standard MP4 video, and unknown messages are viewable offline; the original image DAT, original video file, and original Silk voice are preserved alongside. Images/videos/voice with no local file still retain their message and a `missing` media record. macOS plays archived MP4 directly. With a compatible `silk_v3_decoder` installed, Silk voice is converted to WAV and playable in the viewer; without it, the original Silk is still preserved.

Some newer WeChat versions store the body of revoke notices, location shares, and app messages (link shares/mini programs/quote-replies) as compressed data. Newly built Apps bundle the Zstandard runtime and try to recover this text in memory with input and output limits; source users install the runtime through `brew bundle`. If no compatible runtime is available or decompression fails, the original SQLite values remain in the archive and the viewer shows an unrecognized message. Importing other messages can continue.

## Archive Viewer: Search, Dates and Recovery Stats

- **Search message content**: click the magnifying-glass icon in the viewer toolbar and type a keyword to search message text across **every conversation** (not just conversation titles). Selecting a result switches to that conversation and jumps to, and briefly highlights, the matching message.
  The viewer builds a private, disposable local FTS index; when unavailable it falls back to read-only `LIKE` search. The index contains searchable display text, not source databases or keys, and can be deleted and rebuilt.
- **Jump to date**: use the calendar button to choose a date with messages in the current conversation.
- **Browse both directions**: after a search or date jump, load older messages at the top or newer ones at the bottom. "Jump to latest" returns to the latest messages.
- **Context actions and shortcuts**: copy text, save media or reveal it in Finder. `⌘F` searches all messages, `⌘E` exports the selected conversation, and `⌘J` jumps to the latest messages.
- **Recovery stats**: click the stats icon in the toolbar to see how many messages in the current archive fall into each type (text/image/video/voice/unrecognized), and how media breaks down by recovery status (decoded/raw-only/missing/etc). The stats only read counts already aggregated inside the archive — they never read message text or media content.

## Export a Conversation

Select a conversation in Archive Viewer and choose **Export Chat History** or press `⌘E`. HTML is suitable for offline browser reading; Markdown is readable text, and JSON provides structured `WeChatConversationExport` v1 data. Keep the exported HTML with its media folder so relative media paths continue to work. Conversation export reads only the archive and does not require WeChat, source databases or keys.

## Snapshots and Temporary Plaintext Data

Validation and decryption use a fresh local working directory: directory permissions are `0700`; snapshot and plaintext SQLite file permissions are `0600`. Before and after copying a snapshot, the file set, sizes, and modification times of the database and its `-wal`/`-shm` sidecars are compared; if a change is detected, that database is marked as a validation/export failure and the rest continue processing.

This is a protected, best-effort-stable file snapshot check — it is **not** a SQLite transaction-consistent backup. That's why a real import must happen only after WeChat has fully quit.

If `sqlcipher_export`, detach, plaintext header, or plain SQLite query verification fails, the program deletes the temporary plaintext database along with its `-wal`, `-shm`, and `-journal` sidecars. On success, the plaintext database is moved atomically from the restricted staging directory to the output directory; the output root and any newly created subdirectories are `0700`, and database files are `0600`.

Output files with the same name default to **Skip** rather than silently overwriting; the UI shows `Destination exists`.

## FAQ

For terminal read permissions, check the actual terminal app's Full Disk Access in macOS Privacy & Security, then restart it. Read access does not grant debugger access; for LLDB attachment failures, use `--prepare-copy` and check Developer Tools authorization. Do not re-sign the official WeChat or disable SIP. For download warnings, missing media, disk space and reporting failures, see the [beginner FAQ](docs/getting-started.md#权限与常见问题). Never publish keys, databases, private logs or the `wechat/` directory in an issue.

| Message | What to do |
| --- | --- |
| `Key map is invalid.` | Confirm you selected wx-cli's `all_keys.json`, where every `enc_key` must be 64 hex characters. |
| `SQLCipher runtime unavailable. Install with: brew bundle` | For source builds, run `brew bundle` in the project folder and restart. The loader recognizes Intel Homebrew's `/usr/local` path; this does not imply real-device verification of Intel key extraction. |
| `Database is in use. Please quit WeChat and try again.` | Fully quit WeChat and retry; don't validate while syncing, backing up, or writing. |
| `Key missing` | `all_keys.json` doesn't contain that database's relative path; check whether you selected the correct `db_storage` root. |
| `Key invalid` | A key matched, but it cannot open this database; that item is skipped. |
| `Destination exists` | The output directory already has a file at that relative path. The app will not overwrite it. |
| Full Export says "one of the plain SQLite directory, account directory, or archive destination is nested inside another" | The three directories must not be nested inside each other. The common cause: creating the archive destination inside the plain SQLite export directory — pick a fully independent destination (not a subdirectory of it) instead. |
| Full Export says "destination directory already exists and is not empty" | Choose a new or genuinely empty directory; Full Export never merges into or overwrites an existing archive. |

## Development Verification

After making changes, run:

```bash
swift build
swift test
git diff --check
```

Tests use only randomized keys and synthetic SQLCipher databases — never add real chat records, databases, media, or keys to the project.

## Local attachments and rebuilding an archive

Current source builds create v5 archives and read older v1–v4 archives without changing them. Rebuild into a new folder using the matching plaintext SQLite export and original account media root; keep WeChat exited. The original files and old archive stay unchanged.

```zsh
swift build -c release --product WeChatArchiveCLI
CLI_DIR="$(swift build -c release --show-bin-path)"
"$CLI_DIR/WeChatArchiveCLI" import-plain \
  --db-dir /absolute/path/PlainSQLite \
  --account-root /absolute/path/Account \
  --archive-output /absolute/path/NewArchive \
  --report /absolute/path/new-result.json
```

Omit `--limit` for a full import. This mode does not validate database keys: `keyCoverageChecked` and `completeCoverage` are false. Check `status=completed`, `archiveCreated=true` and `metadata/import-report.json`. Media status counts are per variant, not per message; a single image can have main, HD and thumbnail variants. Missing local data, association failures, copy failures and decode failures are reported separately.

Raw DAT images are preserved when decoding or key discovery fails. File messages are linked only when size and content MD5 match; archived files can be revealed in Finder and included in HTML/JSON/Markdown exports. Deleted or undownloaded attachments, missing resource mappings, sticker formats and embedded forwarded attachments can remain unsupported; original message fields are preserved. Validation does not prove every attachment is present or playable.

The viewer and conversation exporter select successfully decoded image variants, using a usable thumbnail when available. Images available only as unsupported formats such as WXGF show a placeholder; their raw DAT and recovered format bytes remain in the private archive.

APFS is recommended for many small files. On an ExFAT external disk, create a separate APFS sparse disk image in Disk Utility, mount it and save the new archive there. Preserve the existing disk contents. To migrate, copy the whole image, mount it on another Mac and open the archive folder inside. New v5 archives require the latest source build; older released apps may reject them. See [ADR-016](docs/decisions/ADR-016-local-attachment-preservation.md) for implementation boundaries and references.

For an interrupted v5 import, rerun `import-plain` with `--resume`, the same source/account/output and a new report filename. Omit `--limit`. Completed archives are rejected. Resume verifies every stored source row and the account binding before removing only unreferenced managed/staging files and continuing. `messagesImported` is the archive total; `messagesSkipped` counts previously stored rows. A successful final validation is still required.

Structured emoticon messages now display an emoticon marker. Opaque local emoticon caches are linked only through message XML MD5, emoticon database identity and same-account cache paths. `emoticonRawFound` counts these variants separately from ordinary files. Saving encrypted cache bytes does not imply they can be displayed; the index does not read emoticon database keys.
