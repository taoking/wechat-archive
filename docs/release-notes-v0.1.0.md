# WeChat Archive 0.1.0 — Release Notes Draft

## Highlights

- Creates a one-time, local-first `WeChatArchive` from owner-authorized WeChat data.
- Reads the resulting archive without reopening WeChat, source databases, or keys.
- Reconstructs supported text, image, video, and voice timeline entries; raw source rows remain preserved for unsupported messages.
- Shows contact and group identities when locally available, with private avatar placeholders when no local asset was recovered.
- Exports an individual conversation to offline HTML, JSON, or Markdown with viewer-friendly media.
- Remembers non-sensitive workspace locations and the most recently opened archive.

## Privacy

- All processing is local.
- No chat data or keys are uploaded.
- Key-map locations may be remembered, but key-map contents and decryption material are never persisted in preferences or archives.

## Distribution status

- Local release build: `./scripts/build-app.sh`
- Signing: ad-hoc development signing only.
- Notarization: not done.
- This draft intentionally does not create a GitHub Release.
