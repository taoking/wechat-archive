# 导入格式

`ChatImportProvider` 提供两个操作：`preview(at:)` 和 `messages(at:)`。提供器将显式本地 URL 解析为归一化 `Message` 值；持久化属于 `ImportCoordinator` 和 `SQLiteArchiveIndex` 的职责。

## JSON

当前 JSON 提供器接受 Archive v1 Message JSON 对象数组，并使用 Archive v1 的日期和 snake-case 字段定义。

## NDJSON

当前 NDJSON 提供器接受每个非空 UTF-8 行一个 Archive v1 Message 对象。它按行进行概念上的流式处理，不需要一个巨大的 `messages.json` 文件。

## 计划中的来源适配器

- CSV 需要显式的列映射界面。最少字段为时间戳、会话、发送者、类型、内容和媒体路径。
- TXT/HTML 导入必须保留可用来源元数据，并将无法表达的数据标为 `unknown`；不得虚构联系人、媒体或时间。
- 微信数据库导入是在快照／解密／检测之后的 Adapter 管线；参见 [WECHAT_DATABASE.md](WECHAT_DATABASE.md)。

## 增量导入

可用时优先使用 `source_message_id`。否则，后备指纹组合会话 ID、发送者 ID、时间戳、类型、内容 SHA-256 和排序后的媒体哈希。这能防止大多数重复导入，但可能将两条真正相同且没有 ID 的消息视为重复。导入会话会记录读取、插入和跳过数量，供用户审计结果。

## 崩溃安全

导入按有上限的批次写入（默认每批 1,000 条消息），每个索引批次都是一个事务。崩溃后已完成的批次仍保持一致，按已记录策略重新运行导入不会生成重复项。
