# WeChat Archive 格式 v1

## 目标

Archive v1 有意采用普通目录、UTF-8 JSON/NDJSON、媒体文件、SQLite 和 SHA-256 校验和构成。即使没有 WeChat Archive 也应可读取。SQLite 是可选索引，而不是权威存储。

## 布局

```text
WeChatArchive/
├── manifest.json
├── account.json
├── contacts.json
├── conversations.json
├── messages/<stable-conversation-id>/<year>.ndjson
├── media/{images,videos,voice,files,stickers,thumbnails}/<sha-prefix>/<sha256>.bin
├── database/archive.sqlite
├── sources/
├── exports/
└── checksums/SHA256SUMS.txt
```

目录名使用稳定 ID，绝不使用显示名称。这样即使用户显示名称中包含 `/`、emoji 或任意 Unicode，也不会产生路径歧义。媒体内容文件名使用其 SHA-256；MIME 类型和原始类型信息保存在消息元数据中。

## Manifest

`manifest.json` 是 UTF-8 JSON：

```json
{
  "format": "WeChatArchive",
  "version": 1,
  "created_at": "2026-08-16T12:32:15.123Z",
  "updated_at": "2026-08-16T12:32:15.123Z",
  "message_count": 123456,
  "conversation_count": 234,
  "media_count": 45678
}
```

读取器必须拒绝未知的 `format` 或主版本，而不是猜测。未来版本尽可能只做增量扩展；v1→v2 迁移必须在验证成功前保留原始归档不变。

## 元数据文件

`account.json`、`contacts.json` 与 `conversations.json` 是 JSON 对象或数组。ID 都是字符串。只有在来源本来不含这些信息时，联系人显示名称、历史名称和微信 ID 才可以缺失；读取器不得推断缺失信息。

## 消息

`.ndjson` 文件中每一条非空 UTF-8 行对应一个 Message 对象。消息按稳定的 `conversation_id` 和 `source_timezone` 中的年份分区。读取器可以逐行流式读取。

```json
{
  "id": "message-id",
  "source_message_id": "source-id-if-available",
  "conversation_id": "conversation-id",
  "timestamp": "2026-08-16T20:32:15.000Z",
  "source_timezone": "Asia/Shanghai",
  "sender": { "id": "wxid_xxx", "display_name": "张三" },
  "type": "text",
  "content": "晚上一起吃饭吗？",
  "reply_to": null,
  "media": [],
  "raw": null
}
```

支持的 `type` 值包括 `text`、`image`、`video`、`voice`、`file`、`sticker`、`link`、`location`、`contact`、`system`、`reply` 和 `unknown`。未知消息必须在可选的 `raw` 对象中保留来源字段；读取器不得丢弃它们。

`timestamp` 是 ISO 8601 时间点。`source_timezone` 保留来源时区语义，使 UI 可以一致地渲染和分区。

## 媒体

消息的 `media` 是对象数组，包含 `id`、`path`、`sha256`、可选的 `mime`、`size` 和 `category`。`path` 相对于归档根目录。JSON 中不以 Base64 嵌入二进制内容。即使多个消息引用同一对象，内容哈希也只标识一个物理对象。

## 校验和与验证

`checksums/SHA256SUMS.txt` 除自身外，为每个归档文件包含一行：

```text
<64-lowercase-hex-sha256>  messages/conversation-id/2026.ndjson
```

验证会检查 manifest 兼容性、校验和文件语法、文件存在性、哈希一致性、NDJSON 解码及被引用媒体是否存在。报告只包含归档相对路径；绝不得包含消息内容或数据库密钥。

## SQLite 索引

`database/archive.sqlite` 包含带版本的 `contacts`、`conversations`、`participants`、`messages`、`media_assets`、`message_media`、`imports` 和 `archive_metadata` 索引。它可以被丢弃并由可移植文件重建。实现必须使用迁移，而不能删除不匹配的索引。
