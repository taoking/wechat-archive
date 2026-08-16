# WeChat Archive

WeChat Archive 是一个 macOS 本地优先的个人微信聊天记录归档项目。它将用户本人有权访问的本地数据转换成长期可读的开放格式，而不是把 Word 或 PDF 当作唯一备份。

## Why not only Word/PDF?

Word、PDF 和 HTML 适合阅读或分享；它们不适合作为唯一数据源。Archive v1 将消息保存在按会话和年份分区的 NDJSON 中，将媒体保存在普通文件中，并用 SQLite 作为可重建的搜索索引。即使本应用不再存在，仍可用任意 JSON、SQLite 和文件工具访问数据。

## Archive Format

归档根目录包含 `manifest.json`、账户/联系人/会话 JSON、`messages/<conversation>/<year>.ndjson`、`media/`、`database/archive.sqlite` 和 `checksums/SHA256SUMS.txt`。完整规范见 [ARCHIVE_FORMAT.md](ARCHIVE_FORMAT.md)。

## Privacy

所有导入、解密、索引、导出与校验都设计为在本机完成。项目没有服务器、遥测、Analytics 或 crash upload。数据库密钥不会写进归档、日志、普通文件或 Git。详见 [PRIVACY.md](PRIVACY.md) 与 [SECURITY.md](SECURITY.md)。

## WeChat Database Import

Core 使用 SQLCipher 支持用户主动提供的十六进制数据库密钥。它会对原始数据库（包括 WAL/SHM）创建一致性快照、以只读方式验证密钥，并只从受限工作目录中的快照生成临时明文副本；原库不会被修改。密钥不会写进归档、日志、命令行参数或普通文件。

首次运行前执行 `brew bundle`（或 `brew install sqlcipher`）安装本机 SQLCipher 运行库。当前支持的是 SQLCipher 解密层；微信各版本数据库解析仍由保守的 Adapter 检测控制，未知 schema 会拒绝解析而非猜测。详见 [WECHAT_DATABASE.md](WECHAT_DATABASE.md)。

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
