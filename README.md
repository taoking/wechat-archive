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

## Phase 2: Plain SQLite Schema Discovery

选择第一阶段生成的普通 SQLite 根目录后，**Schema Discovery** 会递归以只读方式打开 `*.db`，采集 SQLite 版本、页数、表/索引/视图/触发器数量、字段、主键、索引、外键和聚合行数。它只使用 `SQLITE_OPEN_READONLY`，不需要 `all_keys.json` 或数据库密钥，也不会读取聊天文本、联系人字段值、BLOB 或字符串样本。

分析会根据路径、表名、字段名、索引和表结构，将数据库标记为 Detected、Likely 或 Unknown，并输出消息、联系人、会话、群聊、媒体等候选。报告写入所选导出根目录下的 `SchemaReports/`：包含 `schema-summary.json`、`schema-summary.md` 和每个数据库的 Markdown 报告。报告目录权限为 `0700`，报告文件为 `0600`；其中不包含绝对路径、数据库值、密钥或聊天内容。

## Phase 3A: Limited Message & Media Link Discovery

**Message Discovery** 读取用户主动选择的普通 SQLite 根目录中的 `SchemaReports/schema-summary.json`，将其中的消息候选表供用户选择；再以 `SQLITE_OPEN_READONLY` 最多抽取 500 行，保留 SQLite 原始存储类型，推断字段、时间单位和原始 type 的样本分布。它不会进行完整消息导出或写入 Archive v1。

用户还必须显式选择本人原始微信数据根目录，才会开始本地媒体定位。扫描器以流式方式读取普通文件的有限头部、识别媒体 magic bytes（也可识别 JPEG/PNG/GIF 的单字节 XOR 文件头），并只在路径或媒体标识符已缩小候选范围时计算 MD5。文件名本身永远不会被视作匹配证据；没有足够证据时结果保持 unresolved。

一次运行最多验证一条或少量受限的消息—媒体链路。页面可在本机展示短预览以供用户确认，`.local-analysis/` 下的 `message-discovery.json` 与 `message-discovery.md` 只写入结构、字段映射、聚合 type 分布和解析结果；它们不包含消息文本、BLOB、媒体 ID、哈希、文件名或绝对路径。目录为 `0700`，文件为 `0600`，并已被 Git 忽略。

## Not in the current discovery scope

当前仍不解析或转换完整消息、联系人或媒体，也不生成 Word、Excel、HTML 或可分享的聊天导出。Phase 3A 的受限验证只是下一阶段 Adapter 开发的证据，不是完整内容解析或归档结果。

## Backup

建议使用 3-2-1：Mac 上的归档、外部磁盘或 NAS、以及一份离线副本。定期运行 archive verification，保存 `SHA256SUMS.txt` 随归档一起复制。

## Development

需要 macOS、Swift 6、SQLite 和 CryptoKit；UI 需要完整 Xcode（SwiftUI macro plugins 不随 Command Line Tools 提供）。核心库和零依赖测试的命令详见 [DEVELOPMENT.md](DEVELOPMENT.md)。

项目架构与阶段计划分别见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [PLAN.md](PLAN.md)。
