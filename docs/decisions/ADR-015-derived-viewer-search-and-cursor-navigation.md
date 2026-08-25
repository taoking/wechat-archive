# ADR-015：派生搜索索引与游标时间线导航

- 状态：已接受
- 日期：2026-08-25

## 背景

一次性导出的 `WeChatArchive` 是长期保存的源事实，但阅读大型归档仍需要快速的全文检索、日期跳转以及从任意中间位置继续向前或向后浏览。直接对 `archive.sqlite` 使用 `LIKE '%关键词%'` 可以作为兼容方案，却不能为数万条聊天记录提供理想体验。

搜索索引包含聊天正文，因此它也必须遵守 Archive 的本地优先和私有权限边界；同时不应迫使用户为了启用搜索而重新导出 Archive 或改变既有 schema。

## 决策

1. Viewer 在本机 Application Support 的 `WeChat Archive/SearchIndexes/` 下为每份 Archive 创建可删除的 SQLite FTS5 派生索引。该目录为 `0700`，索引文件为 `0600`，并排除系统备份。
2. 索引只从只读 `archive.sqlite` 读取显示所需字段：消息标识、会话标识与名称、时间戳和文本。它绝不保存来源数据库、表、SQLite 行标识、原始 SQLite 值或任何密钥。
3. 索引以归档规范路径的哈希命名；采用数据库大小、修改时间、消息数和 schema 版本组成的指纹。指纹一致时复用，不一致时安全重建。
4. 优先使用 FTS5 `trigram` tokenizer 以支持中文子串检索。运行时不提供该 tokenizer 时使用 `unicode61`；一到两个字符的查询及索引不可用期间均回退到只读 `LIKE` 查询，搜索功能不会完全失效。
5. 索引在后台构建，Viewer 可立即打开。用户取消时只删除暂存索引，Archive 不受影响。
6. 时间线使用 `(timestamp, source_sequence, source_database, source_table, source_sqlite_rowid, message_id)` 的稳定 keyset cursor。搜索或日期跳转围绕锚点加载有限窗口，随后可分别请求更早或更新的页，而不依赖会在大型会话中退化的 `OFFSET`。

## 考虑过的替代方案

### 将 FTS 表写入 Archive schema

拒绝原因：旧 Archive 需要被修改，索引与可长期保存的源事实耦合，也使用户无法单独删除聊天正文的本地缓存。

### 仅保留 `LIKE` 搜索

拒绝原因：实现简单，但大型 Archive 的检索延迟不可预测，也无法为中文子串提供稳定的交互体验。

### 继续用 OFFSET 在跳转后分页

拒绝原因：相同时间戳、长会话和跳转到中间位置时更容易产生重复、遗漏或线性扫描成本。源顺序游标能保留既有重建排序规则。

## 后果

- 删除 SearchIndexes 只会使下一次搜索重新建立索引，不会影响 Archive、媒体或会话导出。
- Viewer 的所有检索、日期桶和游标查询继续只依赖 Archive；不会重新访问微信目录、普通 SQLite、SQLCipher 或密钥。
- FTS5 在不同 macOS SQLite runtime 的 tokenizer 能力可能不同，但兼容回退路径保持可用。
