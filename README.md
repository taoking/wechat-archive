# 微信聊天归档（WeChat Archive）

WeChat Archive 是一个 macOS 本地优先的个人聊天记录归档工具。它把用户本人有权访问的微信本地数据转换为独立的 `WeChatArchive`：之后无需再打开微信、原始数据库或密钥，也能离线查看聊天记录和已归档媒体。

> 所有处理都在本机进行。项目不上传聊天内容、媒体或密钥。

## 可以做什么

- 将用户主动选择的微信 SQLCipher 数据库导出为普通 SQLite。
- 一次性创建完整、私有的 `WeChatArchive`，保存全部消息源字段与 BLOB。
- 在只读归档查看器中浏览私聊和群聊：文本、图片、视频、WAV 语音，以及未支持消息的安全占位。
- 显示已恢复的联系人、群成员和头像；本地没有头像时使用占位图。
- 在本机派生的可删除搜索索引中全文搜索消息，并按日期跳转、双向浏览长会话。
- 为一个会话生成可独立保存的离线 HTML、JSON 或 Markdown，并复制可播放/可显示的媒体。
- 记住非敏感的工作目录和最近打开的归档；不会保存数据库密钥、图片密钥或聊天正文到偏好设置。

## 快速开始

### 1. 准备环境

从源码运行需要 macOS 15、完整 Xcode 和 Homebrew SQLCipher：

```zsh
brew bundle
```

若项目没有 Brewfile，可使用：

```zsh
brew install sqlcipher
```

### 2. 启动应用

```zsh
./scripts/run-app.sh
```

应用启动后默认显示“归档查看器”。没有已有归档时，选择“创建完整归档”。

### 3. 创建一次性完整归档

1. **完全退出微信**，避免尚未写入数据库的 WAL 数据遗漏。
2. 在“高级工具 → 数据库导出”中选择自己的 `db_storage` 目录及 wx-cli 生成的 `all_keys.json`，扫描、验证并导出普通 SQLite。
3. 在“完整导出”中选择普通 SQLite 根目录、自己的微信账号数据根目录和一个新的空归档目录。
4. 完成后点击“打开归档”。

归档会创建 `archive.sqlite`、manifest、媒体和聚合导入报告。目录权限为私有权限；源数据库和微信媒体只读访问，不会被修改。

### 4. 日常查看与导出会话

以后重新打开应用会恢复最近一次有效归档。选择会话即可从最新消息开始浏览，并可向前或向后继续加载。工具栏提供全局消息搜索和当前会话的日期跳转；搜索索引仅保存在本机 Application Support，可随时删除并自动重建。

在会话右上角选择“导出聊天记录”：

- **HTML**：浏览器离线打开，图片、视频和 WAV 语音使用相对本地路径。
- **JSON**：稳定的 `WeChatConversationExport` v1 结构，默认隐藏源数据库和原始身份字段。
- **Markdown**：适合长期保存或版本管理的可读文本。

会话导出只读取 `WeChatArchive`；不需要重新选择微信目录、普通 SQLite、SQLCipher 或任何密钥。

## 当前范围

支持并已按本机链路验证的主要体验：

- 文本、图片、视频、语音（Silk 保留原始数据并在可用的本机 decoder 下转为 WAV）
- 联系人、群聊、群成员、消息方向、已归档头像
- 独立归档查看、全文消息搜索、日期导航与单会话导出
- 未支持消息仍会以完整原始 SQLite 值保存到 Archive，不会因当前查看器无法解释而丢失

当前版本有意不提供实时同步、增量合并、云端上传、写回微信或新的微信消息协议解析。

## 隐私与安全

- 只处理用户本人明确选择的本地数据。
- 原始微信数据库、媒体和普通 SQLite 均以只读方式使用。
- `all_keys.json` 仅在执行扫描时读入内存；不会复制进 Archive、导出目录、日志、Git 或 UserDefaults。
- Archive 与会话导出分别使用私有目录/文件权限。
- HTML 导出会转义聊天文本，不会执行聊天内容中的 HTML 或脚本。

详细边界见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 与 `docs/decisions/`。

## 高级工具

“数据库导出”“结构发现”“消息发现”和诊断页面用于首次导出或本地排查；它们不需要作为日常查看聊天记录的入口。

## 开发与验证

```zsh
swift build
swift test
git diff --check
```

创建本地 Release 配置 App：

```zsh
./scripts/build-app.sh
```

产物位于 `dist/WeChat Archive.app`，会内置 SQLCipher 与所需 OpenSSL runtime，因而不依赖目标机器上的 Homebrew。Silk → WAV 仍需要一个兼容的本机 `silk_v3_decoder`；已经归档的 WAV 语音无需该工具即可播放。同理，撤回通知/位置/链接/引用回复等消息文本的恢复需要本机 `zstd`（`brew bundle` 已包含）；缺少时这些消息按原样保留为未识别类型，不影响归档其余部分。该 App 采用 ad-hoc 本地签名；尚未进行 Developer ID 签名或 notarization。更多开发说明见 [DEVELOPMENT.md](DEVELOPMENT.md)，使用细节见 [USAGE.md](USAGE.md)（[English](USAGE.en.md)）。
