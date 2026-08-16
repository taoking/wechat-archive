# WeChat Archive

WeChat Archive 是一个 macOS 本地优先的个人微信聊天记录归档项目。它将用户本人有权访问的本地数据转换成长期可读的开放格式，而不是把 Word 或 PDF 当作唯一备份。

## Why not only Word/PDF?

Word、PDF 和 HTML 适合阅读或分享；它们不适合作为唯一数据源。长期归档格式将在后续阶段定义；当前阶段先把用户已有的加密数据库转换为可由标准 SQLite 工具读取的普通数据库。

## Archive Format

归档根目录包含 `manifest.json`、账户/联系人/会话 JSON、`messages/<conversation>/<year>.ndjson`、`media/`、`database/archive.sqlite` 和 `checksums/SHA256SUMS.txt`。完整规范见 [ARCHIVE_FORMAT.md](ARCHIVE_FORMAT.md)。

## Privacy

所有导入、解密、索引、导出与校验都设计为在本机完成。项目没有服务器、遥测、Analytics 或 crash upload。数据库密钥不会写进归档、日志、普通文件或 Git。详见 [PRIVACY.md](PRIVACY.md) 与 [SECURITY.md](SECURITY.md)。

## Phase 1: Export Plain SQLite Databases

第一阶段读取用户主动选择的微信 `db_storage` 目录和 wx-cli `all_keys.json`。应用递归扫描 `*.db`，以数据库相对路径（如 `contact/contact.db`）匹配 `enc_key`，逐个验证后将成功项导出成普通 SQLite 数据库。导出结果可直接由 `sqlite3` 或 SQLite GUI 打开；目录结构与原数据库根目录保持一致。

每次操作都将原始数据库及其 `-wal` / `-shm` sidecar 复制到受限本地工作目录，并在复制前后检测源文件变化；原库不会被修改。该机制是受保护的、尽力保持稳定的文件快照，不是 transaction-consistent SQLite backup。为确保导出正确性，请在操作前完全退出微信。

`all_keys.json` 和 key 仅在内存中使用，不写入导出目录、日志、命令行参数、普通文件或 Git。导出的根目录/子目录权限为 `0700`，数据库文件为 `0600`；同名文件默认跳过，不覆盖。首次运行前执行 `brew bundle`（或 `brew install sqlcipher`）安装本机 SQLCipher 运行库。详细步骤见 [USAGE.md](USAGE.md)。

## Not in this phase

本阶段不解析聊天消息、联系人或媒体，也不提供 JSON、NDJSON、HTML、CSV、Word、PDF、Excel、全文搜索或 schema 分析。验收目标仅为：根据 `all_keys.json` 导出可由普通 SQLite 工具打开的数据库。

## Backup

建议使用 3-2-1：Mac 上的归档、外部磁盘或 NAS、以及一份离线副本。定期运行 archive verification，保存 `SHA256SUMS.txt` 随归档一起复制。

## Development

需要 macOS、Swift 6、SQLite 和 CryptoKit；UI 需要完整 Xcode（SwiftUI macro plugins 不随 Command Line Tools 提供）。核心库和零依赖测试的命令详见 [DEVELOPMENT.md](DEVELOPMENT.md)。

项目架构与阶段计划分别见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [PLAN.md](PLAN.md)。
