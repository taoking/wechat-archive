# 开发说明

## 要求

- 产品目标为 macOS 15+；以 Apple Silicon 为主，同时应保持 Intel 兼容性。
- Swift 6、Foundation、CryptoKit 和 SQLite3。
- 编译／运行 SwiftUI App 与 XCTest 需要完整 Xcode。仅安装 Command Line Tools 可以编译 Core，但会缺少 SwiftUI macro plugin 和 XCTest。
- 加密数据库导入需要 SQLCipher 4.17+：推荐执行 `brew bundle`，或执行 `brew install sqlcipher`。

运行时加载器会明确报告 SQLCipher dylib 缺失。它尚不强制检查已加载库的版本；在实现该后续工作前，请保持 SQLCipher 4.17+ 要求。

## 目录布局

```text
Sources/Core/     可移植归档、索引、导入、导出和微信边界
Sources/App/      SwiftUI 展示层
Tests/            合成且不含私有数据的测试
docs/decisions/   架构决策记录
```

## 测试流程

Core 测试有意全部使用合成数据：不允许真实微信记录、图片、密钥或数据库。使用以下命令运行 XCTest：

```bash
swift test
```

测试套件涵盖模型序列化、NDJSON 分区、SHA-256 媒体去重、增量导入、SQLite FTS 筛选、离线导出转义、归档验证、SQLCipher 正确密钥／错误密钥／普通 SQLite 导出行为、wx-cli key map 解析、相对路径匹配、顺序批量验证／导出、`-wal`／`-shm` 快照复制、变更拒绝、受保护权限、目标不覆盖行为和普通 SQLite sidecar 清理。每次行为变更前先添加测试。

## 本地 App 构建

在完整 Xcode 中打开 package，并选择 `WeChatArchive` 可执行产品。若从终端启动，运行 `./scripts/run-app.sh`；它会创建本地 `.app` 包装，使文件面板能够成为前台 macOS 窗口。Package 有意保持轻量依赖；未经威胁模型和许可证审查，不得添加网络 package。

最终用户配置、安全批量导出与运行时故障排查见 [USAGE.md](USAGE.md)。

## 编码规则

- 产品流程中绝不使用 `try!`、强制解包或 `fatalError`。
- 在提供器边界将所有导入数据视为不可信。
- 绑定所有 SQLite 值；不得把用户输入拼接进 SQL。
- 不得打印消息正文、密钥、密钥十六进制值或完整私有路径。
- UI 不得进入 SQL／解密／解析器代码。
- 代码变更后运行完整 Core 测试套件。
