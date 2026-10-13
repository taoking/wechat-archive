# Third-party source notice

The Rust Mach memory scanner (`native/src/scanner.rs`) is derived from
[`hum0r23/wx-cli`](https://github.com/hum0r23/wx-cli), pinned to commit
`6dc57e69333bc6037a284bd3cec22f8043ac5e39`, specifically
`src/scanner/macos.rs`. The upstream project is licensed under Apache-2.0;
the complete license is included as `LICENSE` in this directory.

Local modifications: explicit process/database selection; Apple SDK pack(4)
layout; memory-read diagnostics; binary/ASCII candidate matching; optional local
CommonCrypto candidates; first-page SQLCipher 4 HMAC verification; rejection of
empty output; exclusive private output files; generic errors without private paths.

The rest of the repository remains under its root MIT license. No Tencent app,
upstream executable, real key, database, media, or runtime output is distributed.
