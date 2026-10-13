# 微信聊天归档（WeChat Archive）

WeChat Archive 是一个用于 **Mac 微信聊天记录导出、备份、归档和离线查看**的本地工具。它把用户本人有权访问的微信本地数据转换为独立的 `WeChatArchive`：之后无需再打开微信、原始数据库或密钥，也能搜索聊天记录、查看已归档媒体，并导出 HTML、JSON、Markdown。

WeChat chat history export, backup and offline viewer for macOS. The latest source includes a local database key extraction → SQLCipher validation → archive workflow.

> 所有处理都在本机进行。项目不上传聊天内容、媒体或密钥。

**第一次使用：先看 [新手入门与下载指南](docs/getting-started.md)。** 详细操作见 [中文使用说明](USAGE.md) / [English usage guide](USAGE.en.md)；取钥参数见 [取钥与全流程说明](tools/wechat_keys/README.md)。

## 这个项目适合谁

- 希望把自己 Mac 上的微信私聊、群聊保存成独立归档，之后离线查找。
- 希望将某个会话导出为浏览器可打开的 HTML 或可读文本。
- 已有 `all_keys.json`，希望验证密钥、解密自己的 SQLCipher 数据库并归档。
- 已有 `WeChatArchive`，希望换到另一台兼容的 Mac 继续查看。

这里的“迁移”指**归档文件迁移**，不能把记录导入回微信，也不替代微信官方的手机／电脑聊天迁移功能。当前运行平台为 macOS 15+；没有 Windows、Linux、Android 或 iPhone 取钥入口。取钥已在 Apple Silicon + 微信 4.1.15 验收，Intel 与其他微信版本仍需实机验证。

## 下载哪个版本

| 你的目标 | 下载入口 | 需要准备什么 |
| --- | --- | --- |
| 查看已有归档，或使用旧版桌面工具 | [Releases](https://github.com/taoking/wechat-archive/releases)，选择适合的 App 附件 | v0.3.0 已提供 Apple Silicon App；内置 SQLCipher，无需为查看归档安装 Xcode |
| 从取钥开始完成新流程，或使用最新功能 | [最新源码 ZIP](https://github.com/taoking/wechat-archive/archive/refs/heads/main.zip)，或下方 Git 下载命令 | macOS 15+、完整 Xcode、Homebrew、Python 3.9+；首次取钥还需要 Rust |

**v0.3.0 App 不包含新集成的取钥模块。** GitHub 的 `Source code (zip)` 和首页 `Code → Download ZIP` 是源码，不能当作安装包双击运行。源码 ZIP 请先解压；终端后续命令都在解压后的项目根目录执行。App 为本地 ad-hoc 签名，尚未公证；首次打开可能出现系统提示，处理方式见新手指南。

## 可以做什么

- 使用项目内取钥模块，串联数据库密钥导出、验证、解密和一次性归档。
- 将用户主动选择的微信 SQLCipher 数据库导出为普通 SQLite。
- 一次性创建完整、私有的 `WeChatArchive`，保存全部消息源字段与 BLOB。
- 在只读归档查看器中浏览私聊和群聊：文本、图片、视频、WAV 语音、已关联文件附件，以及未支持消息的安全占位。
- 显示已恢复的联系人、群成员和头像；本地没有头像时使用占位图。
- 在本机派生的可删除搜索索引中全文搜索消息，并按日期跳转、双向浏览长会话。
- 为一个会话生成可独立保存的离线 HTML、JSON 或 Markdown，并复制可播放/可显示的媒体。
- 原始图片解码失败时仍保留 DAT；按内容去重媒体，并提供按类型和状态统计的附件报告。
- 记住非敏感的工作目录和最近打开的归档；不会保存数据库密钥、图片密钥或聊天正文到偏好设置。

## 快速开始

### 1. 准备环境

以下命令针对最新源码。安装完整 Xcode（仅 Command Line Tools 不足以运行桌面应用）和 Homebrew 后，在终端下载并进入项目；已经下载 ZIP 的用户直接进入解压后的文件夹：

```zsh
git clone https://github.com/taoking/wechat-archive.git
cd wechat-archive
```

安装项目依赖：

```zsh
brew bundle
brew install rust  # 首次取钥时需要；仅查看归档不需要
python3 --version  # 取钥流程要求 3.9 或更高
```

### 2. 根据你的情况选择入口

| 你已经有的文件 | 下一步 |
| --- | --- |
| 什么都没有，但 Mac 微信已登录自己的账号 | 按步骤 3 使用全流程命令 |
| `all_keys.json` 和对应的微信账号目录 | 按 [已有密钥步骤](docs/getting-started.md#已有密钥时) 跳过重新取钥 |
| 普通 SQLite 导出和账号媒体目录 | 在应用的“完整导出”中创建归档 |
| 含 `archive.sqlite` 的归档文件夹 | 启动应用，在“归档查看器”打开该文件夹 |

源码启动桌面应用：

```zsh
./scripts/run-app.sh
```

应用启动后默认显示“归档查看器”。“创建完整归档”需要已有普通 SQLite 导出；首次取钥请继续下一步。

### 3. 创建一次性完整归档

也可以从取钥开始，用项目内的统一入口完成验证、解密和完整归档：

```zsh
./scripts/archive-wechat.command --prepare-copy --open-viewer
```

1. 在官方微信登录要归档的本人账号，然后执行上面的命令。
2. 流程会退出当前微信并打开临时副本；等待登录页出现，**先不要点击“进入微信”**。
3. 按终端提示回车，看到采集提示后，再在副本点击“进入微信”，完成手机确认／系统授权，并打开需要归档的聊天。
4. 等待验证和归档完成。成功时终端显示验证数量和归档位置，查看器自动打开。

官方应用保持原签名，运行数据全部在被 Git 忽略的 `wechat/`。不要给整个命令加 `sudo`；遇到权限问题按 [权限说明](docs/getting-started.md#权限与常见问题) 处理。缺少密钥默认停止，只有逐项明确指定的数据库可以排除；这类结果不代表全部数据库均已覆盖。
仅导出密钥使用 `./scripts/extract-keys.command --prepare-copy`。已有密钥复用、保留选项、权限和限制见 [取钥与全流程说明](tools/wechat_keys/README.md)。

桌面应用逐步操作方式仍然可用：

1. **完全退出微信**，避免尚未写入数据库的 WAL 数据遗漏。
2. 在“高级工具 → 数据库导出”中选择自己的 `db_storage` 目录及 wx-cli 生成的 `all_keys.json`，扫描、验证并导出普通 SQLite。
3. 在“完整导出”中选择普通 SQLite 根目录、自己的微信账号数据根目录和一个新的空归档目录。
4. 完成后点击“打开归档”。

归档会创建 `archive.sqlite`、manifest、媒体和聚合导入报告。目录权限为私有权限；源数据库和微信媒体只读访问，不会被修改。

统一入口的最终归档在 `wechat/archives/<run-id>/`，运行报告在 `wechat/runs/<run-id>/result.json`。备份时复制**整个归档文件夹**，包含媒体；仅复制 `archive.sqlite` 不够。完整归档流程默认清理本次临时密钥和明文工作库，单独导出密钥则保留私有 JSON。成功判断与清理说明见 [新手指南](docs/getting-started.md#如何确认完成)。

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

本机没有下载过的媒体不能凭空恢复；当前查看器不能解释的消息仍保存其源字段。已有实机取钥验收不等于所有微信版本都兼容。一个本机账号已完成已有普通 SQLite 的全量导入及数量核对，但该次最终全量校验按用户要求跳过；跨版本取钥到完整归档的端到端验收仍未完成，自动化端到端测试使用合成数据。大量媒体会占用较多空间，请为快照、工作库和归档预留容量。导入后需要独立复核时，见[单独校验已有归档](USAGE.md#单独校验已有归档)。

## 隐私与安全

- 只处理用户本人明确选择的本地数据。
- 原始微信数据库、媒体和普通 SQLite 均以只读方式使用。
- `all_keys.json` 仅在执行扫描时读入内存；不会复制进 Archive、导出目录、日志、Git 或 UserDefaults。
- 新增取钥模块在明确导出密钥时创建私有 JSON；完整归档流程默认清理本次临时密钥。代码和私有运行输出分离，详见模块说明。
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

产物位于 `dist/WeChat Archive.app`，内置 SQLCipher、所需 OpenSSL 与 Zstandard 运行库，不依赖目标机器上的 Homebrew。撤回通知、位置、链接及引用回复等压缩文本优先在有大小限制的内存中解压。Silk → WAV 仍需要一个兼容的本机 `silk_v3_decoder`；已经归档的 WAV 语音无需该工具即可播放。该 App 采用 ad-hoc 本地签名；尚未进行 Developer ID 签名或 notarization。更多开发说明见 [DEVELOPMENT.md](DEVELOPMENT.md)，使用细节见 [USAGE.md](USAGE.md)（[English](USAGE.en.md)）。

## 问题反馈

请先查看 [新手常见问题](docs/getting-started.md#权限与常见问题)。仍无法解决时，在 [GitHub Issues](https://github.com/taoking/wechat-archive/issues) 提供 macOS 版本、芯片类型、微信版本、使用的入口和脱敏后的错误提示。不要上传 `wechat/`、`all_keys.json`、数据库、聊天截图或含个人信息的完整日志。

## 搜索关键词

微信聊天记录导出、微信聊天记录备份、微信聊天记录归档、Mac 微信、macOS 微信、微信数据库密钥、SQLCipher 解密、本地聊天记录搜索、离线聊天查看器、微信聊天记录导出 HTML / JSON / Markdown、归档文件迁移（不写回微信）。

WeChat Archive · WeChat chat history export · WeChat backup · WeChat database key extraction · SQLCipher · macOS · offline chat viewer · local-first · privacy · SwiftUI · HTML export · JSON export · Markdown export.

最新源码的附件覆盖与从普通 SQLite 重新归档说明见 [附件保存与重新归档](USAGE.md#附件保存与重新归档)。新归档使用 v5，旧发布版 App 可能无法打开；请用最新源码构建的 App。
