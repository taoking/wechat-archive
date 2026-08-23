# 架构

## 决策摘要

可移植归档是唯一事实来源。SQLite 是可由 NDJSON 和元数据重建的索引投影，绝不能成为唯一的持久副本。应用只在本机运行，不包含网络客户端。

```text
用户明确选择的本地来源
  → 受保护、尽力保持一致的文件快照（.db + -wal + -shm；请先退出微信）
  → 本地密钥提供器／本地解密器
  → 有版本的适配器和解析器
  → 归一化的 Message / Contact / Conversation / MediaAsset
  → Archive v1（NDJSON + JSON + 媒体 + 校验和）
  → SQLite 索引／FTS5
  → HTML、JSON、NDJSON、CSV（DOCX/PDF 适配器后续提供）
```

## 模块

- `Sources/Core/Models.swift` 包含可移植的契约，以及一致的 `ArchiveError` 语义。
- `Archive.swift` 负责 NDJSON、manifest、媒体内容寻址和验证。
- `SQLiteArchiveIndex.swift` 仅负责迁移、事务、FTS 和参数化 SQL。
- `Import.swift` 定义与来源无关的提供器和批处理协调器。
- `Export.swift` 定义独立导出器；任何导出器都不得修改归档。
- `WeChatSecurity.swift` 与 `SQLCipherDatabaseDecryptor.swift` 包含有作用域的密钥提供器、SQLCipher 原始密钥处理和本地解密器。
- `WeChatDatabase.swift` 包含快照和 Adapter 检测边界。
- `SQLiteSchemaScanner.swift` 负责第二阶段普通 SQLite 的只读结构检查、安全标识符引用、FTS 内部表识别、结构分类和 schema 指纹；它绝不读取数据库值。
- `SQLiteSchemaReportWriter.swift` 写入第二阶段 JSON/Markdown 报告，目录权限为 `0700`、文件权限为 `0600`，并对报告路径脱敏；它绝不打开源数据库。
- `WeChatMessageDiscovery.swift` 负责第三阶段 A 的有上限、只读源行读取器、源值类型保留、字段／时间戳／类型推断及结构化 XML/JSON payload 检查。原始记录只保留在内存中，且有意不遵从 `Codable`。
- `WeChatMediaDiscovery.swift` 负责所选根目录的流式媒体发现、文件 magic／尺寸检查、安全的单字节 XOR 图片头识别、已导出 hardlink 映射查询和按证据排序的媒体解析。它不会复制、移动或批量哈希媒体库；仅凭文件名的证据仍会保持未解析状态。
- `MessageDiscoveryReportWriter.swift` 仅从脱敏 DTO 写入第三阶段 A 的受保护报告；它排除源值、BLOB 字节、媒体标识符、哈希、文件名和绝对路径。
- `Sources/App` 只负责协调 Core 服务；它绝不直接执行 SQL、处理原始 SQLCipher API 或解析数据库行。

## 数据与错误契约

文件／提供器边界的输入均视为不可信数据。它们在进入索引前会被解码为 `Message` 模型。数据库查询绑定值，而不是拼接用户输入。公开方法返回值或抛出 `ArchiveError`；错误文本有意保持通用，绝不包含密钥、消息正文或完整用户路径。

`SearchQuery.limit` 会被限制在 1–500。可用时使用消息源 ID 去重。没有源 ID 的记录使用已记录的后备指纹：会话、发送者、时间戳、类型、内容哈希和排序后的媒体哈希；对真正完全相同的消息，这一策略可能出现极少数误判。

## 并发与安全

索引以 SQLite `FULLMUTEX` 打开，每个导入批次都是一个事务。已完成的批次可在中断后保留；同一来源可安全地再次导入。快照使用 SQLite 的 `-wal` 与 `-shm` sidecar，拥有一个 `0700` 工作目录，将复制文件设为 `0600`，并在复制前后比较源文件集合与属性。来源发生变化时会提示退出微信后重试，而不是静默导入不完整数据库。这些检查只是尽力而为，不能证明获得了单个 SQLite 事务快照；UI 和文档均要求在真实导入前完全退出微信。

第二阶段仅在第一阶段导出后运行。它发现用户所选导出根目录下的 `.db` 文件，拒绝符号链接和路径逃逸，并以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` 打开每个文件。它使用从 schema 元数据得到的带引号标识符，查询 `sqlite_master`、PRAGMA 元数据和聚合 `COUNT(*)`，不选择任何已存储数据库值。源相对路径仅保留在 UI 本地；报告省略绝对路径，并隐藏 wxid 风格的路径组成部分。

第三阶段 A 是第二阶段“仅 schema”规则的显式、有界例外。用户选择一个第二阶段消息表候选项和最多 100／250／500 行样本；Core 仅以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` 打开该普通 SQLite 数据库。`SQLiteSourceValue` 保留 NULL、INTEGER、REAL、TEXT 和 BLOB 的身份，而原始值只留在内存中。payload 解析禁用 XML 外部实体解析，并仅保留允许列表中的结构化媒体元数据。另行选择的原始媒体根目录在不跟随符号链接的前提下扫描；扫描流式、有上限、可取消，且在解析器缩小到明确候选项前只读取文件头。单字节 XOR 包装的 JPEG/PNG/GIF 文件头可被识别；对于小文件，可在内存中规范化字节供 ImageIO 或 MD5 验证，绝不改动来源。报告使用专用安全 DTO，因此不会意外序列化任何原始样本值。

## 依赖决策

首个实现直接使用 macOS Foundation、CryptoKit 和 SQLite3。未选择 GRDB，因为本地 v1 需要一个小且可检查的依赖面，以及显式的 SQLite FTS5／迁移行为。未来若采用 GRDB，必须新增 ADR，且必须保持与 Archive v1 的兼容性。

## 决策记录

参见 [docs/decisions/ADR-001-portable-archive-source-of-truth.md](docs/decisions/ADR-001-portable-archive-source-of-truth.md) 与 [docs/decisions/ADR-002-local-only-key-boundary.md](docs/decisions/ADR-002-local-only-key-boundary.md)。
