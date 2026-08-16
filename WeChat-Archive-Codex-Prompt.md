# WeChat Archive — Codex 开发 Prompt

你现在位于一个全新的项目目录中。

请从零设计并实现一个 **macOS 本地微信聊天记录归档、管理、搜索和导出应用**。

项目暂定名称：

# WeChat Archive

目标不是简单制作一个“聊天记录转 Word 工具”，而是建立一个可以长期保存几十年的、开放格式的个人聊天数据归档系统。

---

# 1. 核心目标

应用需要把用户自己的微信聊天数据整理成：

```text
微信本地数据库 / 已有导出数据
        ↓
Import / Parser
        ↓
Normalized Message Model
        ↓
┌────────────────────┐
│ JSON / NDJSON       │
│ SQLite              │
│ Media Files         │
└────────────────────┘
        ↓
┌────────┬────────┬────────┬─────────┐
 HTML    Word     PDF      CSV/Search
```

其中：

```text
JSON / NDJSON + Media
```

是长期保存的核心格式。

SQLite 用于：

- 快速查询
- 全文搜索
- 联系人管理
- 群聊管理
- 时间范围筛选
- 消息类型筛选
- 后续 AI / RAG 接入

HTML / DOCX / PDF / CSV 只是导出层。

---

# 2. 项目核心设计原则

始终遵循：

```text
Open Format
Local First
Lossless Where Possible
Searchable
Portable
Verifiable
Extensible
```

优先级：

1. 数据完整
2. 长期可读
3. 可恢复 / 可验证
4. 可搜索
5. 可扩展
6. UI 美观

不要为了 UI 牺牲数据完整性。

---

# 3. 数据安全与 Local First

这是一个处理私人聊天记录的应用。

所有处理默认：

```text
100% 本地完成
```

禁止：

- 上传聊天记录到服务器
- 上传图片
- 上传视频
- 上传语音
- 上传数据库
- 上传数据库密钥
- 使用第三方在线解析 API
- 默认启用遥测
- 默认启用 Analytics
- 默认启用 Crash Upload

应用无需服务器即可完整工作。

---

# 4. 数据解密与微信密钥使用规则

本项目用于用户 **备份、归档和转换本人微信聊天记录**。

因此允许应用支持：

- 使用用户本人微信账号对应的数据库密钥
- 使用用户已经获得并主动提供的微信数据库密钥
- 在用户自己的 Mac 上读取本地微信数据
- 使用本地密钥解密用户自己的微信数据库
- 将解密后的聊天记录转换为 JSON / NDJSON / SQLite / HTML / DOCX / PDF / CSV
- 提取并整理用户自己的图片、视频、语音、文件等媒体数据
- 对用户自己的历史微信数据库进行版本识别、解析、迁移和归档
- 所有解密、解析和转换过程均在本机执行

安全边界不是：

```text
禁止解密微信数据库
```

而是：

```text
只处理用户本人有权访问的数据
+
只在本机处理
+
密钥绝不上传
+
原始数据库只读
+
解密和解析过程透明
+
不以获取第三方账号数据为目标
```

对于用户自己的微信聊天记录：

```text
Local Database
+
User-owned Key
+
Local Decryption
+
Local Export
```

属于本项目需要支持的核心能力。

---

# 5. Local Key Support

设计独立密钥管理模块：

```swift
protocol WeChatKeyProvider
```

支持：

```text
ManualKeyProvider
LocalKeyFileProvider
EnvironmentKeyProvider
KeychainKeyProvider
```

未来如果实现其他仅针对：

```text
当前用户本人
+
当前 Mac
+
当前微信客户端
```

的密钥发现方式，也必须和 Archive / Parser 解耦。

数据流程：

```text
用户自己的微信数据
        ↓
Encrypted Database
        ↓
Local Key Provider
        ↓
Local Decryption
        ↓
Raw Parsed Records
        ↓
Normalized Message Model
        ↓
JSON / NDJSON / SQLite / Media
        ↓
HTML / Word / PDF / CSV
```

---

# 6. 密钥安全原则

微信数据库密钥属于高度敏感数据。

必须：

```text
Local Only
```

密钥禁止：

- 上传服务器
- 上传第三方 API
- 写入 Analytics
- 写入 Crash Report
- 写入普通日志
- 提交 Git
- 写入测试 Fixture
- 明文长期保存到项目目录
- 通过网络发送

日志中禁止输出：

```text
database key
完整 key
key hex
解密后的敏感数据库内容
```

错误日志只允许：

```text
Key unavailable
Key invalid
Database decryption failed
Unsupported database version
```

---

# 7. 密钥输入 UI

第一阶段至少支持：

```text
手动输入数据库密钥
```

示例：

```text
Import WeChat Database

Database:
[ Choose Database ]

Database Key:
[ •••••••••••••••••••••••••• ]

☑ Do not persist key

[ Validate ]
[ Import ]
```

默认：

```text
Do not persist key = ON
```

即：

密钥只存在于当前进程内存。

任务结束后释放。

---

# 8. Keychain

如果未来提供：

```text
Remember Key
```

必须使用：

```text
macOS Keychain
```

禁止保存在：

```text
UserDefaults
plist
JSON
SQLite
普通文本文件
日志
```

用户必须主动选择：

```text
Remember this key in macOS Keychain
```

默认关闭。

---

# 9. Secure Memory

尽可能减少密钥生命周期。

```text
Input
 ↓
Validate
 ↓
Decrypt
 ↓
Release
```

不要在多个 ViewModel、Singleton 或全局变量中复制数据库密钥。

不要将 key 作为普通 App State 长期保存。

---

# 10. 数据所有权限制

本项目仅用于：

```text
用户本人
+
用户本人有权访问的数据
```

不得设计：

```text
输入别人的微信号 → 获取聊天记录
```

不得实现以获取第三方数据为目标的能力，例如：

- 批量获取其他账号数据库
- 远程窃取数据库
- 远程收集数据库密钥
- 将他人的数据库上传解析
- 针对其他登录用户的数据收集

如果实现本机密钥发现能力：

必须满足：

```text
当前 macOS 登录用户
+
当前用户本人微信客户端
+
本地执行
+
用户主动触发
```

不得偷偷后台扫描。

---

# 11. 技术要求

目标平台：

```text
macOS
```

优先：

```text
macOS 15+
Apple Silicon
```

架构尽量兼容：

```text
Intel Mac
```

推荐：

```text
Swift
SwiftUI
Swift Concurrency
SQLite
```

数据库可使用：

```text
GRDB
```

如果使用 GRDB，请在 `ARCHITECTURE.md` 中说明原因。

优先使用原生 macOS API。

---

# 12. 项目结构

采用模块化设计，例如：

```text
WeChatArchive/
├── App/
├── Core/
│   ├── Models/
│   ├── Database/
│   ├── Import/
│   ├── Export/
│   ├── Search/
│   ├── Media/
│   ├── Integrity/
│   ├── WeChat/
│   │   ├── Database/
│   │   ├── Keys/
│   │   ├── Parser/
│   │   └── Adapters/
│   └── Utilities/
│
├── Features/
│   ├── Dashboard/
│   ├── Conversations/
│   ├── Contacts/
│   ├── ChatViewer/
│   ├── Search/
│   ├── Import/
│   ├── Export/
│   └── Settings/
│
├── Tests/
└── Docs/
```

不要把所有代码堆在 View 或 ViewModel。

---

# 13. 微信数据库模块

建议：

```text
Core/
    WeChat/
        Database/
            WeChatDatabaseDetector.swift
            WeChatDatabaseReader.swift
            WeChatDatabaseDecryptor.swift
            DatabaseSnapshotter.swift

        Keys/
            WeChatKeyProvider.swift
            ManualKeyProvider.swift
            LocalKeyFileProvider.swift
            EnvironmentKeyProvider.swift
            KeychainKeyProvider.swift

        Parser/
            WeChatMessageParser.swift
            WeChatContactParser.swift
            WeChatConversationParser.swift

        Adapters/
            WeChatDatabaseAdapter.swift
            WeChatMacV3Adapter.swift
            WeChatMacV4Adapter.swift
```

UI 不允许直接执行：

```text
SQL + 解密 + Message 转换
```

正确架构：

```text
UI
 ↓
ImportCoordinator
 ↓
WeChatDatabaseProvider
 ↓
Decryptor
 ↓
Adapter / Parser
 ↓
Normalized Models
 ↓
Archive
```

---

# 14. 原始数据库保护

默认：

```text
READ ONLY
```

读取微信数据库。

绝对不要修改微信正在使用的数据库。

如果 SQLite 需要 WAL / SHM 或临时写操作：

优先复制到独立工作目录。

```text
Original WeChat Database
        ↓
Read-only Snapshot / Copy
        ↓
Working Copy
        ↓
Decrypt / Parse
```

原文件必须保持不变。

---

# 15. Database Snapshot

如果微信正在运行，需要考虑：

```text
.db
.db-wal
.db-shm
```

的一致性。

不得只复制：

```text
xxx.db
```

而忽略 WAL 导致最新消息丢失。

设计：

```swift
DatabaseSnapshotter
```

负责创建一致性快照。

如果无法安全创建一致快照：

应明确提示用户关闭微信后重试。

---

# 16. 解密数据库生命周期

解密数据库只作为：

```text
Temporary Working Data
```

默认完成导入后删除。

用户长期保存的是：

```text
Archive/
    NDJSON
    SQLite
    Media
    JSON
```

而不是：

```text
decrypted_wechat.db
```

只有用户明确选择：

```text
Keep decrypted database copy
```

才允许保存，并显示明显隐私提示。

---

# 17. 微信版本兼容

不要将 Parser 写死为单一版本。

定义：

```swift
protocol WeChatDatabaseAdapter
```

可实现：

```text
WeChatMacV3Adapter
WeChatMacV4Adapter
```

通过：

```text
schema
table
column
metadata
```

识别数据库版本。

未知版本：

```text
Unsupported WeChat database version
```

不要强行解析。

---

# 18. 核心数据模型

至少：

```text
Message
Conversation
Contact
MediaAsset
Participant
ImportSource
ImportSession
ArchiveMetadata
```

---

# 19. Message 示例

```json
{
  "id": "message-id",
  "conversation_id": "conversation-id",
  "timestamp": "2026-08-16T20:32:15+08:00",
  "sender": {
    "id": "wxid_xxx",
    "display_name": "张三"
  },
  "type": "text",
  "content": "晚上一起吃饭吗？",
  "reply_to": null,
  "media": null
}
```

---

# 20. 消息类型

至少支持：

```text
text
image
video
voice
file
sticker
link
location
contact
system
reply
unknown
```

不要把所有非文本消息简单变成：

```text
[图片]
```

必须保存原始类型和关联信息。

---

# 21. Unknown Message

遇到未知类型：

不要丢弃。

保存：

```text
type = unknown
```

以及：

```text
raw payload
```

或：

```text
sourceMetadata
```

未来 Parser 升级后仍能重新解释。

---

# 22. 保留原始信息

Normalized Model 之外允许：

```json
{
  "raw": {}
}
```

或：

```text
sourceMetadata
```

尽量做到：

```text
Lossless Where Possible
```

---

# 23. 群聊

正确保存：

```text
Group
Participant
Message Sender
```

不得把微信群内所有消息错误标记成群名称发送。

---

# 24. 时间

内部使用：

```text
Date
```

Archive 使用：

```text
ISO 8601
```

并保留时区。

不要只存 Unix Timestamp 而丢失来源时区语义。

---

# 25. 媒体文件

图片、视频、语音、文件不要 Base64 放进 JSON。

使用：

```text
media/
├── images/
├── videos/
├── voice/
├── files/
├── stickers/
└── thumbnails/
```

消息通过相对路径引用。

示例：

```json
{
  "type": "image",
  "media": {
    "path": "../../media/images/ab/abcdef.jpg",
    "sha256": "...",
    "mime": "image/jpeg",
    "size": 3819281
  }
}
```

---

# 26. 媒体去重

使用：

```text
SHA-256
```

相同媒体：

```text
只保存一份物理文件
```

数据库可以多个 Message 指向同一 MediaAsset。

不得仅根据文件名判断重复。

---

# 27. Archive 文件格式

设计稳定、开放、可迁移的 Archive Format。

建议：

```text
WeChatArchive/
│
├── manifest.json
├── account.json
├── contacts.json
├── conversations.json
│
├── messages/
│   ├── conversation-id-001/
│   │   ├── 2023.ndjson
│   │   ├── 2024.ndjson
│   │   ├── 2025.ndjson
│   │   └── 2026.ndjson
│
├── media/
│   ├── images/
│   ├── videos/
│   ├── voice/
│   ├── files/
│   └── stickers/
│
├── database/
│   └── archive.sqlite
│
├── sources/
│
├── exports/
│
└── checksums/
    └── SHA256SUMS.txt
```

---

# 28. NDJSON

大量消息不要使用单个巨大 `messages.json`。

优先：

```text
NDJSON
```

一行一条 Message。

按：

```text
会话 + 年份
```

拆分。

例如：

```text
messages/
    conversation-001/
        2024.ndjson
        2025.ndjson
        2026.ndjson
```

---

# 29. manifest.json

必须有 Archive Version。

例如：

```json
{
  "format": "WeChatArchive",
  "version": 1,
  "created_at": "...",
  "updated_at": "...",
  "message_count": 123456,
  "conversation_count": 234,
  "media_count": 45678
}
```

未来支持：

```text
ArchiveFormat v1
ArchiveFormat v2
```

并设计 Migration。

---

# 30. SQLite

SQLite 是查询索引，不是唯一数据源。

至少：

```text
contacts
conversations
participants
messages
media_assets
message_media
imports
archive_metadata
```

针对：

```text
conversation_id
sender_id
timestamp
message_type
content
```

建立合理索引。

---

# 31. Database Migration

从第一天实现数据库版本管理。

例如：

```text
v1
v2
v3
```

禁止：

```text
Schema 不对就删库重建
```

---

# 32. 全文搜索

支持：

```text
SQLite FTS5
```

用户搜索：

```text
黄果树
```

可以快速找到所有相关消息。

支持组合筛选：

```text
关键词
联系人
群聊
时间范围
消息类型
发送者
```

---

# 33. Import Provider 架构

定义：

```swift
protocol ChatImportProvider
```

至少：

```text
WeChatDatabaseImportProvider
JSONImportProvider
NDJSONImportProvider
CSVImportProvider
TXTImportProvider
HTMLImportProvider
```

核心 Archive 不应依赖某一种微信数据库格式。

---

# 34. Import 页面

入口：

```text
Import Data

┌─────────────────────────────┐
│ WeChat Database             │
│ Import your local database  │
│                             │
│ [ Select Database ]         │
└─────────────────────────────┘

┌─────────────────────────────┐
│ Archive / Export File       │
│                             │
│ JSON / NDJSON / CSV         │
│                             │
│ [ Select Files ]            │
└─────────────────────────────┘
```

---

# 35. 微信数据库 Import UI

选择数据库后：

```text
WeChat Database

Database Version:
Detected / Unknown

Encryption:
Encrypted

Database Key:
[••••••••••••••••••]

☑ Do not persist key

[Validate Key]
```

验证成功：

```text
✓ Database key valid

Conversations      182
Messages           842,192
Media              71,382

[Preview Import]
```

---

# 36. Import Preview

导入之前显示：

```text
发现联系人：xxx
发现会话：xxx
发现消息：xxx
发现图片：xxx
发现视频：xxx
发现文件：xxx
```

用户确认后才正式导入。

---

# 37. Import Progress

大量导入必须：

```text
异步
可取消
显示进度
```

例如：

```text
正在导入

284,123 / 842,192

33.7%

图片 18,492
视频 1,204
```

不要求精确剩余时间。

---

# 38. ImportSession

每次 Import 创建：

```text
ImportSession
```

记录：

```text
source
file hash
startedAt
finishedAt
status
messagesRead
messagesInserted
messagesSkipped
errors
```

---

# 39. Import History

显示：

```text
2026-08-16
来源：wechat-data
新增消息：18,292
重复：114,233
新增媒体：2,844
```

---

# 40. 增量导入

第二次导入：

```text
不要重复添加旧消息
```

优先使用：

```text
sourceMessageId
```

若不存在，再综合：

```text
conversation
sender
timestamp
type
content hash
media hash
```

建立稳定的去重策略。

必须在文档中说明可能误判。

---

# 41. Crash Safety

Import 使用事务和合理 Batch。

例如：

```text
1000 messages / transaction
```

如果导入过程中 App 崩溃：

- 数据库不能损坏
- 已完成 Batch 应保持一致
- 可以重新执行或继续
- 不产生大量重复数据

---

# 42. 不可变原始数据原则

导入时可以选择复制原始数据到：

```text
sources/
    import-0001/
```

Normalized Data 和 Source Data 分离。

未来 Parser 升级可以：

```text
重新解析
```

---

# 43. 聊天浏览界面

使用类似聊天软件的时间线。

左侧：

```text
会话列表
```

右侧：

```text
聊天时间线
```

显示：

```text
头像
昵称
时间
文本
图片
视频缩略图
文件
语音
引用消息
```

---

# 44. 大数据性能

考虑：

```text
几十万
甚至几百万条消息
```

禁止一次性加载整个聊天。

实现：

```text
分页
Lazy Loading
Virtualized List
```

例如每次：

```text
100～500 条
```

---

# 45. 时间导航

支持：

```text
按年份
按月份
按日期
```

快速跳转。

---

# 46. 图片查看

图片：

```text
单击 → 大图
```

支持：

```text
上一张
下一张
原图
文件位置
消息位置
Quick Look
```

---

# 47. 视频

优先：

```text
AVKit
```

本地播放。

不要为了播放复制一份视频到永久目录。

---

# 48. 语音

系统支持格式：

直接播放。

未知格式：

定义：

```swift
protocol VoiceDecoder
```

保留原始文件，不得因为暂时不能播放而丢弃。

---

# 49. Dashboard

首页显示：

```text
WeChat Archive

842,192 Messages
237 Conversations
68,921 Photos
1,482 Videos

Last Import
2026-08-16

Archive Health
✓ Healthy
```

---

# 50. 联系人页面

显示导入数据中实际存在的：

```text
昵称
历史昵称
微信 ID
消息数量
图片数量
视频数量
文件数量
第一次聊天
最后一次聊天
共同群聊
```

禁止猜测缺失数据。

---

# 51. Search UI

全局搜索：

```text
Search Messages
```

结果显示：

```text
联系人
时间
消息片段
```

点击结果：

```text
跳转到原聊天位置
```

---

# 52. JSON / NDJSON 导出

支持：

```text
JSON
NDJSON
```

可选：

```text
Include media metadata
```

---

# 53. CSV 导出

字段至少：

```text
timestamp
conversation
sender
type
content
media_path
```

方便：

```text
Excel
Python
数据分析
```

---

# 54. HTML 导出

重点功能。

支持：

```text
单个联系人
群聊
指定时间范围
整个会话
```

输出：

```text
index.html
media/
```

HTML 必须：

```text
完全离线可打开
```

不得依赖 CDN。

---

# 55. HTML UI

尽量模拟现代聊天界面：

```text
日期分割
发送者
头像
气泡
图片
视频
文件
时间
回复
```

同时保持结构简单。

目标：

即使几十年后，没有本应用，也可以直接浏览。

---

# 56. DOCX

支持 Word 导出。

如果 Swift 原生 DOCX 成本高：

1. 抽象 Exporter
2. 先实现 HTML
3. 再使用成熟库或 OpenXML

不要为了 DOCX 破坏核心架构。

对于大型聊天，支持：

```text
按年份拆分
```

例如：

```text
张三-2024.docx
张三-2025.docx
张三-2026.docx
```

---

# 57. PDF

大型聊天默认：

```text
按年份拆分
```

不要默认生成单个数万页 PDF。

---

# 58. Export UI

例如：

```text
导出会话

格式：

☑ HTML
☑ JSON
☐ NDJSON
☐ CSV
☐ Word
☐ PDF

时间：

○ 全部
○ 自定义

媒体：

☑ 图片
☑ 视频
☑ 语音
☑ 文件
```

---

# 59. Archive Integrity

提供：

```text
Verify Archive
```

检查：

```text
JSON 是否可解析
NDJSON 是否损坏
媒体是否存在
SHA256 是否匹配
数据库记录是否一致
引用文件是否缺失
```

报告：

```text
Archive Health

Messages: 842,192
Media: 71,832

Missing files: 0
Corrupted files: 0
Database errors: 0

Status:
Healthy
```

---

# 60. SHA256SUMS

生成：

```text
checksums/SHA256SUMS.txt
```

用于长期存档校验。

---

# 61. Archive Statistics

支持：

```text
总消息
联系人
群聊
图片
视频
语音
文件
最早聊天时间
最新聊天时间
Archive 大小
```

---

# 62. Backup Strategy

Settings 中加入 Backup 页面。

建议用户采用：

```text
3-2-1 Backup
```

例如：

```text
Mac
+
移动硬盘 / NAS
+
另一个离线备份
```

不要求实现云同步。

---

# 63. Privacy 页面

Settings：

```text
Privacy
```

明确说明：

```text
聊天记录不会发送到服务器。
数据库密钥不会发送到服务器。
应用没有后台上传服务。
```

如果未来增加任何网络功能：

必须默认关闭。

---

# 64. UI

使用：

```text
SwiftUI
NavigationSplitView
```

布局：

```text
┌────────────┬───────────────────────────────┐
│ Archive    │                               │
│ Chats      │                               │
│ Contacts   │        Main Content           │
│ Search     │                               │
│ Imports    │                               │
│ Exports    │                               │
│ Settings   │                               │
└────────────┴───────────────────────────────┘
```

---

# 65. Dark Mode

支持：

```text
Light
Dark
System
```

禁止硬编码导致深色模式不可读。

---

# 66. Accessibility

基础支持：

```text
VoiceOver
Dynamic Type
Keyboard Navigation
```

---

# 67. 大数据测试

生成完全人工 Fixture：

```text
1,000 messages
10,000 messages
100,000 messages
1,000,000 messages
```

测试：

```text
数据库插入
FTS 搜索
会话打开
分页
导出
```

禁止真实微信数据进入仓库。

---

# 68. 自动化测试

至少覆盖：

```text
Message model
Archive encoder
Archive decoder
NDJSON read/write
SHA256
Media deduplication
Incremental import
SQLite migration
FTS search
JSON exporter
HTML exporter
Archive verification
ImportSession
Database adapter detection
```

---

# 69. 错误处理

不要使用：

```swift
try!
force unwrap
fatalError
```

处理正常业务流程。

如果单条消息损坏：

```text
记录错误
继续其它消息
```

不要因为一条坏数据导致整个 Archive 导入失败。

---

# 70. Logging

实现本地日志。

禁止输出：

```text
完整聊天文本
完整数据库密钥
key hex
私人消息内容
完整敏感路径
```

日志优先：

```text
messageId
conversationId hash
error type
adapter version
```

---

# 71. 文件名安全

联系人可能包含：

```text
/
:
emoji
中文
特殊字符
```

不要直接用 displayName 作为唯一目录名。

内部目录使用：

```text
conversation UUID / Stable ID
```

显示名存 Metadata。

---

# 72. Git

初始化：

```bash
git init
```

提供：

```text
.gitignore
README.md
LICENSE
```

禁止提交：

```text
真实聊天记录
真实图片
真实数据库
数据库密钥
测试账号数据
DerivedData
临时解密数据库
```

---

# 73. 文档

创建：

```text
README.md
PLAN.md
ARCHITECTURE.md
ARCHIVE_FORMAT.md
PRIVACY.md
SECURITY.md
IMPORT_FORMAT.md
WECHAT_DATABASE.md
DEVELOPMENT.md
```

---

# 74. ARCHIVE_FORMAT.md

重点描述：

```text
Archive v1
```

包括：

```text
manifest
contacts
conversations
messages
media
checksums
```

目标：

即使未来 WeChat Archive 应用不存在，

开发者只看：

```text
ARCHIVE_FORMAT.md
```

也能解析用户的数据。

---

# 75. WECHAT_DATABASE.md

记录：

- 支持的 macOS 微信版本
- 支持的数据库版本
- Adapter 识别方式
- 数据库文件布局
- WAL / SHM 处理方式
- Key 输入方式
- Keychain 安全策略
- 临时解密数据生命周期
- 已支持消息类型
- 未支持消息类型
- 已知限制

不要在文档中记录任何真实用户密钥。

---

# 76. README

包括：

## What is WeChat Archive?

## Why not only Word/PDF?

## Archive Format

## Privacy

## WeChat Database Import

## Import

## Export

## Search

## Backup

## Development

---

# 77. 开发阶段

不要一次把所有功能写完。

按阶段开发、构建、测试和验收。

---

# Phase 0 — Architecture / Foundation

完成：

```text
项目初始化
目录结构
数据模型
SQLite Schema
Database Migration
Archive Format v1
Importer / Exporter Protocol
WeChat Adapter Protocol
文档
测试基础
```

---

# Phase 1A — Open Format Import

完成：

```text
JSON Import
NDJSON Import
CSV 基础
Import Preview
Import Progress
Import History
Deduplication
```

目的：

先验证整个 Archive 架构。

---

# Phase 1B — Local WeChat Database Import

完成：

```text
微信数据库选择
DatabaseSnapshotter
数据库版本识别
手动 Key 输入
Key Validation
本地解密层
WeChatDatabaseAdapter
联系人解析
会话解析
文本消息解析
Normalized Model 转换
Archive Import
```

这一阶段只处理：

```text
用户本人
+
本机数据
+
用户主动提供 / 本地合法持有的 Key
```

所有处理本地完成。

---

# Phase 2 — Archive

完成：

```text
Archive Writer
Archive Reader
Media Store
SHA256
Media Deduplication
Integrity Verification
```

---

# Phase 3 — WeChat Rich Message Parsing

逐步增加：

```text
图片
视频
语音
文件
引用消息
表情
链接
系统消息
未知消息 Raw Preservation
```

---

# Phase 4 — Chat Browser

完成：

```text
Conversation List
Message Timeline
Pagination
Media Preview
Date Navigation
```

---

# Phase 5 — Search

完成：

```text
SQLite FTS5
Global Search
Filter
Jump to Message
```

---

# Phase 6 — Export

完成：

```text
JSON
NDJSON
CSV
HTML
```

HTML 是这一阶段重点。

---

# Phase 7 — Rich Export

完成：

```text
DOCX
PDF
```

不得影响核心归档功能稳定性。

---

# Phase 8 — Hardening

完成：

```text
百万消息测试
性能优化
Database Migration
Crash Safety
Archive Integrity
Accessibility
Privacy Audit
Security Audit
```

---

# 78. 第一轮任务

现在先完成：

```text
Phase 0
+
Phase 1A 基础骨架
+
Phase 1B 的接口和最小可运行骨架
```

不要急于一次性完成所有微信版本解析。

第一轮重点：

1. 创建 Xcode macOS 工程
2. 建立模块结构
3. 核心数据模型
4. SQLite + Migration
5. Archive Format v1
6. ChatImportProvider
7. JSON / NDJSON Importer
8. Import Preview
9. WeChatDatabaseAdapter Protocol
10. WeChatKeyProvider Protocol
11. ManualKeyProvider
12. DatabaseSnapshotter 接口
13. WeChatDatabaseDetector 接口
14. WeChatDatabaseDecryptor 接口
15. 基础微信数据库 Import UI
16. 测试
17. 文档

---

# 79. 第一轮 UI

应用必须能启动。

Sidebar：

```text
Archive
Chats
Contacts
Search
Imports
Exports
Settings
```

未完成页面允许 Placeholder。

Import 页面：

```text
Import Data

WeChat Database
[ Select Database ]

Open Archive Data
[ JSON / NDJSON ]
```

---

# 80. Sample Dataset

创建：

```text
Tests/Fixtures/
```

人工数据：

```text
Alice
Bob
Family Group
```

包含：

```text
text
image metadata
reply
file
unknown
```

严禁真实微信聊天数据进入测试仓库。

---

# 81. 当前阶段对真实微信数据库的要求

如果当前环境中存在用户自己的微信数据库或用户提供样本：

可以针对它进行：

```text
检测
只读快照
Key 验证
本地解密
Schema 分析
Parser 开发
```

但：

- 不修改原数据库
- 不上传任何数据
- 不输出密钥
- 不把真实数据库复制进 Git
- 不把真实聊天写进测试 Fixture

如果当前没有真实数据库样本：

先完成：

```text
Adapter Architecture
Detector
Decryptor Interface
Key Provider
Import UI
Mock Database Fixture
```

不要阻塞其它 Phase。

---

# 82. 开发纪律

不要只给我方案。

直接：

```text
创建文件
写代码
运行构建
运行测试
修复错误
```

直到当前 Phase 达到可运行状态。

不要因为次要问题停下来等待确认。

合理范围内自行做工程判断。

---

# 83. 完成当前 Phase 前必须执行

至少：

```bash
git status
git diff --check
```

以及：

```text
Build
Unit Tests
```

如果编译失败：

先修复。

---

# 84. 验收标准

第一轮完成后至少得到：

```text
可启动 macOS App
+
SQLite 数据层
+
Migration
+
Archive Format v1
+
JSON / NDJSON Import
+
Import Preview
+
WeChat Database Import UI
+
Key Provider 架构
+
Database Adapter 架构
+
基础测试
+
完整文档
```

---

# 85. 完成后的汇报格式

返回：

```text
## Phase

## Implemented

## Architecture

## Files Added

## Database

## WeChat Database Support

## Security / Privacy

## Tests

## Build Result

## Known Limitations

## Next Phase
```

明确报告：

```text
Tests passed / failed
Build passed / failed
```

禁止把：

```text
未测试
```

描述成：

```text
已经验证
```

---

# 86. 最终长期目标

最终 WeChat Archive 应达到：

```text
微信本地数据
     ↓
可靠导入
     ↓
开放归档
     ↓
独立于微信长期保存
```

即使未来：

```text
微信客户端改变
WeChat Archive 不再维护
某种导出格式消失
```

用户仍然拥有：

```text
NDJSON
JSON
SQLite
Media
HTML
Checksums
Archive Format Documentation
```

并能够继续访问自己的聊天记录。

现在从：

```text
Phase 0
```

开始直接实现。

完成 Phase 0 后，如果工程稳定：

继续 Phase 1A。

同时建立 Phase 1B 所需的微信数据库、Key Provider、Database Adapter、Snapshotter 和 Decryptor 架构骨架。

不要等待确认，直接开始执行。
