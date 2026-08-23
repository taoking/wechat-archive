# WeChat Archive v0.1.0

First usable local-first release of WeChat Archive for macOS.

## Highlights

- Creates a one-time, local-first `WeChatArchive` from owner-authorized WeChat data.
- Reads the resulting archive without reopening WeChat, source databases, or keys.
- Reconstructs supported text, image, video, and voice timeline entries; raw source rows remain preserved for unsupported messages.
- Shows contact and group identities when locally available, with private avatar placeholders when no local asset was recovered.
- Exports an individual conversation to offline HTML, JSON, or Markdown with viewer-friendly media.
- Remembers non-sensitive workspace locations and the most recently opened archive.
- Cancels large-media conversation exports without waiting for a whole file copy.

## Privacy

- All processing is local.
- No chat data or keys are uploaded.
- Key-map locations may be remembered, but key-map contents and decryption material are never persisted in preferences or archives.

## Current Scope

v0.1.0 supports one-time Full Export. It does not provide live
synchronization, incremental backup, or cloud sync. Less common WeChat message
types remain preserved losslessly as unsupported messages.

## Voice Decoder

Raw Silk voice is preserved during archive export. Silk → WAV requires a
compatible locally installed decoder. Existing archived WAV voice messages
remain playable without the WeChat source data.

## Distribution

- The macOS Apple Silicon App bundles SQLCipher and its required OpenSSL
  runtime. Its third-party licenses are included inside the App bundle.
- Signing: AD-HOC.
- Notarization: NOT DONE.
- Because the build is not notarized, macOS may show a security warning on
  first launch.
