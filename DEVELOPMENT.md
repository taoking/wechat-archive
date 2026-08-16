# Development

## Requirements

- macOS 15+ product target; Apple Silicon is primary and Intel should remain compatible.
- Swift 6, Foundation, CryptoKit and SQLite3.
- Full Xcode is required to compile/run the SwiftUI app and XCTest. Command Line Tools alone can compile Core but omit SwiftUI macro plugins and XCTest.

## Layout

```text
Sources/Core/     portable archive, index, imports, exports and WeChat boundaries
Sources/App/      SwiftUI presentation shell
Tests/            artificial, zero-private-data tests
docs/decisions/   architecture decision records
```

## Test workflow

The core tests are intentionally synthetic: no real WeChat record, image, key or database is permitted. In a complete Xcode/SwiftPM installation, configure the package test target with XCTest/Swift Testing discovery. For this repository’s Command Line Tools-only environment, this direct command builds Core with testability and runs the zero-dependency test harness:

```bash
mkdir -p .build/manual
swiftc -emit-library -emit-module -enable-testing -module-name WeChatArchiveCore Sources/Core/*.swift \
  -emit-module-path .build/manual/WeChatArchiveCore.swiftmodule \
  -o .build/manual/libWeChatArchiveCore.dylib
swiftc -enable-testing -I .build/manual -L .build/manual -lWeChatArchiveCore \
  -Xlinker -rpath -Xlinker .build/manual \
  Tests/WeChatArchiveCoreTests/ArchiveCoreTests.swift Tests/ManualTestRunner.swift \
  -o .build/manual/WeChatArchiveCoreTests
.build/manual/WeChatArchiveCoreTests
```

The suite covers model serialization, NDJSON partitioning, SHA-256 media deduplication, incremental import, SQLite FTS filtering, offline export escaping and integrity verification. Add tests before every behavior change.

## Local app build

Open the package in a full Xcode installation and select the `WeChatArchive` executable product. The package is intentionally dependency-light. No network package should be added without a threat-model and license review.

## Coding rules

- Never use `try!`, force unwrap or `fatalError` in product flows.
- Treat all imported data as untrusted at provider boundaries.
- Bind all SQLite values; do not concatenate user input into SQL.
- Do not print message text, keys, key hex or full private paths.
- Keep UI out of SQL/decryption/parser code.
- Run the complete core test suite after code changes.
