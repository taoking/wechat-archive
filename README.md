# WeChat Archive

WeChat Archive 是一个 macOS 本地优先的个人微信聊天记录归档项目。它将用户本人有权访问的本地数据转换成长期可读的开放格式，而不是把 Word 或 PDF 当作唯一备份。

## Why not only Word/PDF?

Word、PDF 和 HTML 适合阅读或分享；它们不适合作为唯一数据源。Archive v1 将消息保存在按会话和年份分区的 NDJSON 中，将媒体保存在普通文件中，并用 SQLite 作为可重建的搜索索引。即使本应用不再存在，仍可用任意 JSON、SQLite 和文件工具访问数据。

## Archive Format

归档根目录包含 `manifest.json`、账户/联系人/会话 JSON、`messages/<conversation>/<year>.ndjson`、`media/`、`database/archive.sqlite` 和 `checksums/SHA256SUMS.txt`。完整规范见 [ARCHIVE_FORMAT.md](ARCHIVE_FORMAT.md)。

## Privacy

所有导入、解密、索引、导出与校验都设计为在本机完成。项目没有服务器、遥测、Analytics 或 crash upload。数据库密钥不会写进归档、日志、普通文件或 Git。详见 [PRIVACY.md](PRIVACY.md) 与 [SECURITY.md](SECURITY.md)。

## WeChat Database Import

Core 定义了只读快照、密钥提供者、解密器和版本化 Adapter 边界。手动密钥、显式本地密钥文件、环境变量和 macOS Keychain provider 都已抽象；默认 UI 不持久化密钥。

本仓库**没有伪装成可用的 SQLCipher 解密实现**。加密数据库导入必须注入一个经过审计的本地 SQLCipher decryptor，之后才可验证密钥及解析微信数据库。当前可直接使用的导入层是已规范化的 JSON/NDJSON 数据。限制和接入点见 [WECHAT_DATABASE.md](WECHAT_DATABASE.md)。

## Import

`ChatImportProvider` 让 JSON、NDJSON、CSV、TXT、HTML 和微信数据库来源保持解耦。JSON 和 NDJSON provider 已实现；其他来源以及各微信数据库 Adapter 是明确的后续适配工作。每次写入会生成 `ImportSession`，并使用 source ID 优先、保守回退指纹的去重策略。

## Export

Core 提供 JSON、NDJSON、CSV 和完全离线的 HTML exporter。HTML 内嵌样式、不使用 CDN，并对消息文本进行 HTML 转义。DOCX/PDF exporter 保留为独立扩展点，避免影响长期归档格式。

## Search

`SQLiteArchiveIndex` 从第一版开始迁移 schema，并建立 SQLite FTS5 索引。支持关键词及会话、发送者、时间、消息类型筛选；列表查询必须设定 1–500 的上限。

## Backup

建议使用 3-2-1：Mac 上的归档、外部磁盘或 NAS、以及一份离线副本。定期运行 archive verification，保存 `SHA256SUMS.txt` 随归档一起复制。

## Development

需要 macOS、Swift 6、SQLite 和 CryptoKit；UI 需要完整 Xcode（SwiftUI macro plugins 不随 Command Line Tools 提供）。核心库和零依赖测试的命令详见 [DEVELOPMENT.md](DEVELOPMENT.md)。

项目架构与阶段计划分别见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [PLAN.md](PLAN.md)。
