# ADR-005：不读取数据库值地检查第一阶段 SQLite 导出

## 状态

已接受

## 日期

2026-08-17

## 背景

第一阶段从用户选择的本地微信 SQLCipher 来源生成普通 SQLite 数据库。在实现消息 Adapter 前，项目需要一种可重复的方法，在真实本地导出中识别消息、联系人、会话和媒体 schema。输入中可能包含私密消息、姓名、wxid 值、BLOB 和用户账号目录下的路径。

## 决策

第二阶段使用 `SQLiteSchemaScanner` 在用户明确选择的普通 SQLite 导出根目录下递归发现普通 `.db` 文件。它拒绝符号链接和逃离所选根目录的文件，每个句柄都以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` 打开。

扫描器只读取 `sqlite_master`、PRAGMA schema 元数据和聚合 `COUNT(*)` 结果。来自 schema 元数据的数据库标识符始终采用双引号，且转义内部引号。它不选择数据库值、文本样本或 BLOB。FTS 虚拟表和 shadow table 会被标记为实现细节，避免被误认为业务消息表。

报告写入器会在所选根目录的 `SchemaReports/` 下生成受保护 JSON 和 Markdown 报告。目录使用 `0700`，报告文件使用 `0600`。报告只保留相对路径，隐藏 wxid 风格路径组成部分，并省略所选根目录、数据库值和 SQL 诊断。

## 后果

- 未来 Adapter 可以针对 schema 指纹组，而不是独立逆向每个分片消息数据库。
- 分类有意采用启发式：`Detected` 需要 schema 证据，`Likely` 可以依赖路径或较弱信号，`Unknown` 仍是有效结果。
- 极大的普通表仍需要顺序执行 `COUNT(*)`；扫描器提供逐库进度和取消检查，不会将行载入内存。
- 本阶段不解析消息，也不创建可移植归档数据；这些属于下一 Adapter 阶段。
