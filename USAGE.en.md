# Usage Guide

*[中文版本见 USAGE.md](USAGE.md)*

Phase 1 of WeChat Archive reads a wx-cli `all_keys.json` you select, matches each database's `enc_key` by its **relative path**, and exports the corresponding SQLCipher databases into plain SQLite databases openable by any ordinary `sqlite3` client or SQLite GUI tool. Phase 2 performs read-only structure discovery on those plain SQLite databases only. Phase 3C can export the plain SQLite export and your original account media into a standalone archive in one pass, viewable offline inside the App.

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

`all_keys.json` is only ever read into memory; it is never copied into the export directory, written to logs, databases, plain files, or Git. Keys are never passed as command-line arguments. After export completes, the app discards the matched keys held in the session; to export again, re-scan and re-validate.

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

Some newer WeChat versions store the body of revoke notices, location shares, and app messages (link shares/mini programs/quote-replies) as compressed data. With `zstd` installed (included in `brew bundle`), export automatically attempts to decompress these and display them as plain text. Without `zstd`, these messages are still fully preserved as their raw SQLite values in the archive — they just display as unrecognized messages in the viewer. No data is lost and the export never fails because of this.

## Archive Viewer: Search and Recovery Stats

- **Search message content**: click the magnifying-glass icon in the viewer toolbar and type a keyword to search message text across **every conversation** (not just conversation titles). Selecting a result switches to that conversation and jumps to, and briefly highlights, the matching message.
  After jumping, a "jumped to a search result" banner appears; you can only page further backward (older) from there — click "Jump to latest" to return to normal browsing at the end of the conversation.
- **Recovery stats**: click the stats icon in the toolbar to see how many messages in the current archive fall into each type (text/image/video/voice/unrecognized), and how media breaks down by recovery status (decoded/raw-only/missing/etc). The stats only read counts already aggregated inside the archive — they never read message text or media content.

## Snapshots and Temporary Plaintext Data

Validation and decryption use a fresh local working directory: directory permissions are `0700`; snapshot and plaintext SQLite file permissions are `0600`. Before and after copying a snapshot, the file set, sizes, and modification times of the database and its `-wal`/`-shm` sidecars are compared; if a change is detected, that database is marked as a validation/export failure and the rest continue processing.

This is a protected, best-effort-stable file snapshot check — it is **not** a SQLite transaction-consistent backup. That's why a real import must happen only after WeChat has fully quit.

If `sqlcipher_export`, detach, plaintext header, or plain SQLite query verification fails, the program deletes the temporary plaintext database along with its `-wal`, `-shm`, and `-journal` sidecars. On success, the plaintext database is moved atomically from the restricted staging directory to the output directory; the output root and any newly created subdirectories are `0700`, and database files are `0600`.

Output files with the same name default to **Skip** rather than silently overwriting; the UI shows `Destination exists`.

## FAQ

| Message | What to do |
| --- | --- |
| `Key map is invalid.` | Confirm you selected wx-cli's `all_keys.json`, where every `enc_key` must be 64 hex characters. |
| `SQLCipher runtime unavailable. Install with: brew bundle` | Run `brew bundle` in the project directory, then restart the app. Intel Macs are also supported via Homebrew SQLCipher under `/usr/local`. |
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
