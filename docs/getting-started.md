# 新手入门与下载指南

[返回项目首页](../README.md) · [详细使用说明](../USAGE.md) · [English guide](../USAGE.en.md) · [取钥参数](../tools/wechat_keys/README.md)

WeChat Archive 帮你把**自己 Mac 上的微信聊天记录**保存成独立归档，之后离线查看、搜索，或导出某个会话为 HTML、JSON、Markdown。首次从微信开始需要取钥；已有归档之后，查看和导出会话都不需要重新取钥。

## 开始前，先确认是否适合你

| 情况 | 是否适合／如何开始 |
| --- | --- |
| macOS 15 或更新版本，需要导出本机微信聊天 | 可以尝试最新源码的完整流程，见下方步骤 |
| 已有 `WeChatArchive` 归档，希望离线查看 | 下载适用的 App，打开归档文件夹即可 |
| 已有对应账号的 `all_keys.json` | 可以跳过取钥，见“已有密钥时” |
| 只有手机记录，没有对应的 Mac 本地数据 | 本项目不能直接从手机读取；先使用微信官方功能准备 Mac 上的数据 |
| 希望把归档重新导入手机或微信 | 当前不支持；这里的迁移是将归档搬到兼容的 Mac 查看 |
| Windows／Linux 或其他人的账号数据 | 当前没有这些平台入口；仅处理本人有权访问的数据 |

取钥实机验证环境为 Apple Silicon Mac + 微信 4.1.15。Intel 的取钥参数有合成测试，尚未进行 Intel 实机验收；不同微信版本可能改变数据库、签名或调试行为，不能保证兼容。真实聊天的完整归档尚未作端到端验收，自动端到端测试使用合成数据。

## 下载应用还是下载源码

### 只需要桌面应用

前往 [GitHub Releases](https://github.com/taoking/wechat-archive/releases)，阅读对应版本的发布说明，再下载 App 的 ZIP 附件。当前 v0.3.0 提供 `WeChat-Archive-v0.3.0-macos-arm64.zip`，其中 `arm64` 指 Apple Silicon（M 系列芯片），不是 Intel 安装包。

解压后将 App 放到“应用程序”文件夹，打开后在“归档查看器”选择已有归档文件夹。该 App 内置 SQLCipher；仅查看归档不需要 Xcode、Rust 或重新连接微信。首次打开的系统提示见下方常见问题。

**v0.3.0 App 不含最新取钥模块。** 如果你还没有密钥或归档，想从取钥开始一次完成，请下载最新源码。不要把 `Source code (zip)` 当成 App 安装包。

### 需要最新的取钥与归档流程

两种方式任选一种：

1. GitHub 首页点击 **Code → Download ZIP**，或下载 [main 源码 ZIP](https://github.com/taoking/wechat-archive/archive/refs/heads/main.zip)。解压后得到项目文件夹，里面应有 `README.md`、`Package.swift`、`scripts/` 和 `tools/`。
2. 会使用 Git 时，在终端执行：

   ```zsh
   git clone https://github.com/taoking/wechat-archive.git
   cd wechat-archive
   ```

ZIP 用户打开“终端”，输入 `cd `（后面有一个空格），把**解压后的项目文件夹**从 Finder 拖入终端，再按回车。后续命令都在这个文件夹内运行，不是在 ZIP 压缩包内运行。复制命令时只复制代码框内容，不要复制提示符或之前的输出。

## 首次安装环境

完整源码流程需要：

| 项目 | 用途 |
| --- | --- |
| macOS 15+ | 运行桌面查看器 |
| [完整 Xcode](https://developer.apple.com/xcode/)，支持 Swift 6 | 构建应用与本地归档工具；只有 Command Line Tools 不够。选择与你的 macOS 兼容的版本 |
| [Homebrew](https://brew.sh/) | 安装 SQLCipher 和 `zstd`；按官网提示安装并设置终端环境 |
| Python 3.9+ | 串联取钥、验证与归档步骤 |
| Rust / Cargo | 首次构建本地取钥工具；已有密钥模式不需要 |
| 足够的可用磁盘空间 | 临时微信副本、数据库快照、明文工作库、最终归档及媒体会同时占用空间 |

安装并打开 Xcode，完成它提示的首次组件安装和许可确认。然后在项目根目录运行：

```zsh
brew bundle
brew install rust
python3 --version
swift --version
```

`brew bundle` 安装项目 `Brewfile` 中的 SQLCipher 与 `zstd`；Rust 另行安装。已有密钥或只查看归档时可以省略 `brew install rust`。首次构建会下载公开依赖，耗时取决于网络和机器；运行阶段不上传聊天内容。

磁盘预检不能精确预测最终全部媒体体积。如果记录和媒体很多，请先预留足够空间，必要时将整个源码项目放到容量充足的磁盘上。最终输出跟随项目的 `wechat/` 目录。

## 第一次从微信开始归档

1. **先登录官方微信。** 保持本人要归档的账号登录。当前入口只自动识别唯一的登录账号，不会根据目录修改时间猜测账号。
2. 在项目根目录的终端执行：

   ```zsh
   ./scripts/archive-wechat.command --prepare-copy --open-viewer
   ```

3. 脚本检查来源、构建工具，退出当前微信并创建临时副本。`--prepare-copy` 表示你同意这一步。官方微信保持原签名，不会被替换；临时副本使用允许调试的签名，可能需要重新登录或授权。
4. **等待临时微信登录页出现，先不要点击“进入微信”。** 回到终端，按提示回车安装捕获。看到采集提示后，才在副本点击“进入微信”。需要手机确认或系统授权时按提示完成。
5. 采集期间打开需要归档的聊天，让相关数据库有机会被加载。默认采集窗口为 180 秒。需要更长时，在开始前增加 `--capture-seconds 300`；上限为 300 秒，延长也不保证获得冷分片或旧迁移库的密钥。
6. 等待取钥、验证、数据库导出、归档创建和校验。临时副本随后退出；如果终端要求完全退出微信再继续，请从微信菜单退出后按回车，不要只关窗口。
7. 成功时终端显示验证数量、归档位置和报告位置，查看器自动打开。第一次搜索可能需要建立本机索引。

不要给整个命令加 `sudo`，不要按旧工具的提示直接重新签名官方微信。这个入口使用临时副本，不需要关闭 SIP，也不会自动修改系统隐私设置。遇到问题请按下方说明检查，不要通过跳过验证来制造“成功”结果。

## 已有密钥时

如果已有当前账号的 `all_keys.json`，**先完全退出微信**，再执行下面的命令。把示例路径换成你自己的绝对路径；有空格的路径保留引号：

```zsh
./scripts/archive-wechat.command \
  --db-dir "/absolute/path/to/db_storage" \
  --keys "/absolute/path/to/all_keys.json" \
  --open-viewer
```

这里的 `db_storage` 是**原始微信账号目录里的数据库目录**。它的父目录用于读取对应媒体；不要选择只复制了数据库、没有账号媒体的临时目录。密钥按数据库相对路径匹配，换账号或混用另一份数据库的密钥可能验证失败。命令不会删除你传入的原始密钥文件。

如果只是想先确认密钥能否使用：

```zsh
python3 tools/wechat_keys/workflow.py validate \
  --db-dir "/absolute/path/to/db_storage" \
  --keys "/absolute/path/to/all_keys.json"
```

只需要导出密钥、以后再归档时：

```zsh
./scripts/extract-keys.command --prepare-copy
```

取钥步骤与前面相同，但此模式会保留私有 `all_keys.json`，不创建聊天归档。

## 如何确认完成

**看到文件夹不等于归档成功。** 先看终端是否正常结束，再打开本次 `wechat/runs/<run-id>/result.json` 检查结果。数据库验证之后才会生成这份报告；如果更早失败，可能只有终端报错和 `tools.log`。

| 报告字段／状态 | 含义 |
| --- | --- |
| `status: "completed"`、`completeCoverage: true` | 本次检测到的加密数据库全部通过验证；完整归档模式还需 `archiveCreated: true` |
| `status: "completed_with_allowed_missing"` | 你显式允许了缺失数据库，流程完成但覆盖不完整；检查 `missingDatabases` |
| `status: "failed"`，或命令报错中止 | 尚未完成；检查失败阶段，不要把残留归档当作完整备份 |
| `archiveCreated: false` | `keys` / `validate` 模式中是正常结果；完整归档模式中不应视为成功 |
| `messagesImported` | 本次实际导入数量；还应结合媒体恢复统计和导入报告检查 |

`completeCoverage` 只说明这次扫描到的数据库密钥覆盖情况，不证明手机、云端、未同步记录或缺失媒体都已保存。打开归档查看你关心的会话、较早日期和媒体，并阅读 `metadata/import-report.json`。没有下载到本机的图片／视频／语音无法凭空恢复。

缺少任何密钥默认停止。请先确认账号、目录和采集时机。确实确认允许排除某个库时，才使用精确相对路径参数，例如 `--allow-missing migrate/unspportmsg.db`。这只是旧迁移库示例，不是默认跳过规则；不能用通配符，也不能跳过已经匹配却验证无效的密钥。详细边界见 [缺失数据库说明](../tools/wechat_keys/README.md#缺失数据库)。

## 输出放在哪里，应该备份什么

每次运行使用新的 `<run-id>`，不会覆盖历史结果：

| 项目内目录 | 内容和保留行为 |
| --- | --- |
| `wechat/archives/<run-id>/` | 最终归档；成功后备份整个文件夹 |
| `wechat/runs/<run-id>/` | 本次结果、工具日志及私有运行信息，供本机排查 |
| `wechat/keys/<run-id>/all_keys.json` | 数据库密钥；单独取钥／验证会保留，完整归档默认清理本次临时密钥 |
| `wechat/databases/<run-id>/` | 普通 SQLite 工作库；完整归档默认清理，`--keep-databases` 可显式保留 |
| `wechat/snapshots/<run-id>/` | 加密数据库快照和配套文件；会保留，可在确认备份完成后按需清理 |

完整归档模式默认在结束或失败时清理本次临时密钥和明文工作库；传入 `--keep-keys` / `--keep-databases` 才保留。用户提供的 `--keys` 原文件不受这个清理影响。临时微信副本和候选密钥会清理，失败归档可能保留；重试会生成新的 run-id。

归档包含 `archive.sqlite`、`archive-manifest.json`、`metadata/` 和媒体等文件，**不要只复制一个 SQLite 文件**。将整个归档复制到另一台兼容的 Mac，再在查看器打开文件夹即可；无需复制数据库密钥。导出的 HTML 也应连同其媒体文件夹一起保存。

`wechat/` 被 Git 忽略，但仍包含私有聊天数据。目录／文件权限不会给备份额外加密；备份盘、云盘权限和共享范围需要你自己管理。确认完整归档与备份可打开后，再按需清理旧工作目录；不要误删原始微信数据或唯一归档副本。

## 日常查看、搜索和导出

源码用户启动桌面应用：

```zsh
./scripts/run-app.sh
```

在“归档查看器”打开归档文件夹，选择会话浏览。`⌘F` 搜索所有会话的消息，日历按钮按当前会话日期跳转，`⌘J` 回到最新消息。首次索引建立期间可能较慢，索引可删除并重建。

选中会话后点击“导出聊天记录”或按 `⌘E`：

| 格式 | 适合用途 |
| --- | --- |
| HTML | 浏览器离线阅读；连同导出的媒体文件夹保存 |
| Markdown | 可读文本，适合整理和长期保存 |
| JSON | 结构化数据，适合后续本地处理 |

语音 WAV 已归档时可直接播放；原始 Silk 转 WAV 需要兼容的本机 `silk_v3_decoder`。未安装时保留原始语音，不能保证可直接播放。不会因为查看器暂不支持某个类型就丢弃其源字段。

## 权限与常见问题

| 现象 | 下一步 |
| --- | --- |
| `brew: command not found` | 先安装 Homebrew，并完成它给出的终端环境设置；重新打开终端后重试 |
| Swift / Xcode 构建失败，只有 Command Line Tools | 安装并首次启动完整 Xcode；在 Xcode 的 Settings → Locations 检查 Command Line Tools 是否选中完整 Xcode |
| `No such file or directory`，找不到 `scripts/` | 确认已解压源码，且终端位于包含 `Package.swift` 的项目根目录；不要输入尖括号占位符 |
| 执行脚本提示 `permission denied` | 在项目根目录执行 `chmod +x scripts/*.sh scripts/*.command` 后再试 |
| 容器不可读、没有加密数据库／目录选择失败 | 确认该 Mac 已同步本人的微信数据、账号目录正确；检查实际运行终端的“系统设置 → 隐私与安全性 → 完全磁盘访问”，授权后重开终端 |
| `task_for_pid` / LLDB 附加失败或拒绝调试 | 使用最新源码的 `--prepare-copy`；检查实际终端的“开发者工具”权限，并按系统提示授权。读取目录的权限不能代替进程调试权限；仍失败请提供脱敏错误与版本信息 |
| 临时副本打不开或需要重新登录 | 完成登录／系统授权；仍异常时停止并查本次私有日志。不要继续对官方应用重签或关闭系统保护 |
| 找到多个账号或来源不一致 | 保留目标账号的唯一微信进程，或明确传入该账号 `db_storage` 的绝对路径；确认临时副本登录同一账号 |
| `Key missing` / 缺少密钥 | 检查账号和相对路径，重新采集并打开相关聊天；冷库可能仍无法取钥。确认允许排除后才能逐项使用 `--allow-missing` |
| `Key invalid` / 密钥验证失败 | 确认密钥与这份数据库来自同一账号和版本；重新取钥，不能通过允许缺失来跳过无效密钥 |
| 微信仍在运行，不能验证 | 从微信菜单完全退出后按终端提示继续；只关窗口不够 |
| 空间不足 | 清理已确认不需要的工作输出，或将项目移到容量充足的磁盘；媒体可能比数据库大很多 |
| 输出存在／目标目录不为空 | 桌面手动导出选新的空目录；统一入口会生成新 run-id，不合并旧结果 |
| 图片／视频缺失、语音不能播放 | 检查本地源媒体是否存在和恢复统计；缺少 Silk decoder 时只能保存原始语音 |
| 下载的 App 首次被 macOS 阻止 | 先确认来自本仓库对应 Release；如系统提供选项，可到“系统设置 → 隐私与安全性”确认“仍要打开”。没有此选项或仍失败时使用源码构建；无需全局关闭 Gatekeeper |

先前直接重签过官方微信且导致无法启动时，需恢复官方签名的应用后再尝试副本流程；不要删除原始账号数据。当前代码会检查官方来源签名，已损坏的官方应用不应继续作为副本来源。

## 反馈问题时提供什么

在 [GitHub Issues](https://github.com/taoking/wechat-archive/issues) 提供：macOS 版本、Apple Silicon／Intel、微信版本、下载方式（App 或源码）、运行入口、失败阶段和脱敏后的错误文字。将账号 ID、用户名、私人路径等替换掉。

**不要公开上传** `wechat/`、`all_keys.json`、数据库、媒体、聊天截图或完整原始日志。更多参数用 `./scripts/archive-wechat.command --help` 查看，隐私边界见 [PRIVACY.md](../PRIVACY.md) 与 [SECURITY.md](../SECURITY.md)。
