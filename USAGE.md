# 使用说明

*[English version: USAGE.en.md](USAGE.en.md)*

WeChat Archive 将本人有权访问的 Mac 微信本地数据保存为独立归档，用于离线浏览、搜索和单会话导出。最新源码已经包含取钥、验证、解密与归档的统一入口；也可以使用桌面应用分步操作。

第一次下载或不熟悉终端，请先阅读 [新手入门与下载指南](docs/getting-started.md)。GitHub v0.3.0 App 可用于桌面查看，但不含最新取钥模块；要从取钥开始请下载 main 源码。源码流程要求 macOS 15+、完整 Xcode、Python 3.9+、Homebrew，首次取钥另需 Rust。Apple Silicon + 微信 4.1.15 已有取钥实机验收，Intel 与其他版本兼容性仍需验证。

## 按你的情况选择

| 已有数据 | 入口 |
| --- | --- |
| Mac 微信账号已登录，尚无密钥 | 下方“从取钥开始一次归档” |
| 对应账号的 `all_keys.json` | 下方“已有密钥复用”，或桌面“数据库导出” |
| 已导出的普通 SQLite 和原始账号媒体 | 桌面“完整导出” |
| 独立 `WeChatArchive` 文件夹 | “归档查看器”，无需微信、源数据库或密钥 |

“归档迁移”是复制整个归档文件夹到另一台兼容的 Mac，不是向微信写回聊天记录。本项目没有手机或 Windows 取钥入口。

## 准备环境

1. 安装完整 Xcode（Command Line Tools 不足以运行 SwiftUI 应用）。
2. 安装 Homebrew 依赖（SQLCipher 运行库，以及用于恢复部分消息文本的 `zstd`）：

   ```bash
   brew bundle
   ```

   或者：

   ```bash
   brew install sqlcipher zstd
   ```

3. 在项目目录运行：

   ```bash
   ./scripts/run-app.sh
   ```

   该脚本将 Swift 可执行文件放入本地 `.app` bundle 后启动，使 macOS 正确激活窗口和文件选择面板。不要用裸的 `swift run WeChatArchive` 进行交互式使用；它不是注册的 `.app` bundle，可能导致 Open 面板无法获得键盘焦点。

   也可以用 Xcode 打开 `Package.swift`，选择 `WeChatArchive` executable 后运行。

## 从取钥开始一次归档

先在官方微信登录目标账号，在项目根目录运行：

```zsh
brew install rust  # 首次构建取钥工具需要
./scripts/archive-wechat.command --prepare-copy --open-viewer
```

脚本将退出当前微信并准备临时副本，官方应用不重签、不替换。等副本登录页出现后，先在终端按回车安装捕获；看到采集提示，再在微信副本点击“进入微信”并按需完成手机确认。采集期间可打开需要归档的聊天，默认窗口 180 秒，最多可用 `--capture-seconds 300` 延长。不要给整个流程加 `sudo`。

随后流程退出微信、创建私有快照、验证密钥、导出普通 SQLite、创建并校验归档，再打开查看器。缺少密钥默认停止；允许排除某个数据库需逐项使用精确的 `--allow-missing`，此时结果明确表示覆盖不完整。无效密钥不能跳过。

最终归档在 `wechat/archives/<run-id>/`，结果在 `wechat/runs/<run-id>/result.json`。检查 `status`、`completeCoverage`、`archiveCreated` 和导入报告，不要仅凭文件夹存在判断成功。完整归档默认清理本次临时密钥和明文工作库；快照和失败归档可能保留。详细步骤及备份方式见 [新手指南](docs/getting-started.md#如何确认完成)，参数及保留选项见 [模块说明](tools/wechat_keys/README.md)。

## 已有密钥复用

完全退出微信，将示例路径替换为自己的绝对路径：

```zsh
./scripts/archive-wechat.command \
  --db-dir "/absolute/path/to/db_storage" \
  --keys "/absolute/path/to/all_keys.json" --open-viewer
```

`db_storage` 必须来自原始账号目录，其父目录用来读取媒体；不要用仅含数据库的快照冒充账号媒体目录。用户传入的原始密钥文件不会删除。仅导出密钥时使用 `./scripts/extract-keys.command --prepare-copy`，结果保存在本次私有 `wechat/keys/<run-id>/all_keys.json`。

以下为桌面应用分步操作。普通 SQLite 是解密后的工作数据库，`WeChatArchive` 才是可独立离线查看的归档。数据库结构／消息发现是高级诊断工具，不是创建归档的必经步骤。

## 批量导出为普通 SQLite

1. **完全退出微信。** 不要只关闭窗口；请从菜单退出并确认没有继续运行。这样能避免遗漏尚未 checkpoint 的 WAL 数据。
2. 打开应用的 **数据库导出** 页面。
3. 点击 **选择文件夹**，选择微信 `db_storage` 根目录。若 macOS 文件选择器无法进入容器目录，可在同一行输入完整绝对路径（支持 `~`），然后点击 **使用路径**；相对路径、普通文件和不存在的目录会被拒绝。确认目录后，应用会检测默认的 `~/.wx-cli/all_keys.json`，但不会读取其中的密钥。
4. 如果默认 key map 存在，界面会显示“可以扫描”，可直接继续；否则点击“使用 `~/.wx-cli/all_keys.json`”或“选择文件”选择 key map。
5. 点击 **扫描**。应用递归查找 `*.db`，将例如 `contact/contact.db` 作为相对路径与 `all_keys.json` 匹配；不会仅按文件名匹配。
6. 点击 **全部验证**。每个已匹配的数据库会依次验证；某一项失败不会阻止其他项继续。
7. 点击 **选择导出文件夹** 选择输出目录，然后点击 **导出数据库**。
8. 使用普通 SQLite 工具打开结果，例如：

   ```bash
   sqlite3 /path/to/Export/contact/contact.db '.tables'
   ```

桌面数据库导出页面只在内存中读取 `all_keys.json`；不会把密钥复制到导出目录、日志、数据库或 Git。密钥不会作为命令行参数传递。导出完成后，应用会丢弃会话中保存的匹配密钥；如需再次导出，请重新扫描和验证。单独取钥脚本则按用户选择创建私有密钥 JSON，保留规则见上方说明。

## 数据库结构发现（普通 SQLite）

1. 打开应用的 **数据库结构发现** 页面。
2. 点击 **选择文件夹**，选择第一阶段导出的普通 SQLite 根目录；若文件选择器不便使用，也可粘贴完整绝对路径后点击 **使用路径**。
3. 点击 **分析数据库**。此阶段不读取 `all_keys.json`、不需要密钥，也不会触碰原 SQLCipher 数据库。
4. 页面会逐库显示进度，并在完成后汇总数据库、表、结构组、消息／联系人／会话／媒体候选数。
5. 点击 **打开报告文件夹** 查看所选根目录下的 `SchemaReports/`：

   ```text
   SchemaReports/
   ├── schema-summary.json
   ├── schema-summary.md
   └── databases/
       └── …-<stable-id>.md
   ```

扫描器仅以 `SQLITE_OPEN_READONLY` 打开常规 `*.db` 文件，逐库／逐表执行 schema 查询和 `COUNT(*)`，不会一次加载数据库内容到内存。报告仅包含相对路径、表／字段／索引／外键名称、声明类型、约束、聚合行数、分类和 schema 指纹；不会包含聊天文本、联系人姓名、wxid、BLOB 数据、TEXT 样本、密钥或用户主目录路径。FTS 虚拟表与 shadow table 会标识为索引结构，不会被当成业务消息表。

分类使用路径和结构启发式，因此 **已检测** 表示存在结构证据，**可能** 表示主要是路径或较弱信号，**未知** 表示没有足够证据；它不是对数据库内容的确定性声明。重复结构的数据库按 schema 指纹分组，为下一阶段选择消息／联系人／会话 Adapter 提供起点。

`SchemaReports/` 及其 `databases/` 子目录会设为 `0700`，报告文件为 `0600`。真实数据库和真实报告已被 `.gitignore` 排除；不要将它们提交到 Git。

## 消息与媒体关联验证（受限）

1. 先完成 **数据库结构发现**，确认普通 SQLite 根目录下有 `SchemaReports/schema-summary.json`。
2. 打开 **消息发现**。选择同一个普通 SQLite 根目录；应用只读取上述第二阶段报告来列出候选消息表。
3. 选择一个候选消息表和 100、250 或 500 行上限。
4. 选择你本人原始微信数据根目录。此输入是必需的：应用不会默认扫描整个磁盘或自动猜测微信目录。
5. 点击 **发现消息与媒体**。它以 `SQLITE_OPEN_READONLY` 打开选中的普通数据库，最多读取所选行数；媒体扫描只读取文件头，并可通过 **取消** 停止。
6. 在 **受限本机验证** 查看字段映射、时间单位、原始类型分布、有限本机预览和媒体解析证据。预览只显示在当前窗口，不会写入报告或上传。
7. 点击 **打开本地分析报告** 查看普通 SQLite 根目录下的 `.local-analysis/`：

   ```text
   .local-analysis/
   ├── message-discovery.json
   └── message-discovery.md
   ```

媒体仅在以下证据存在时才会标记为已解析：精确相对路径、唯一的媒体 ID 路径匹配、在已缩小候选集合内的精确 MD5，或由导出的 hardlink 映射表用精确 MD5 唯一定位到的本地文件。扫描器还能只读识别 JPEG/PNG/GIF 的单字节 XOR 文件头；必要时只在内存中恢复其字节以确认尺寸或精确 MD5，绝不修改原文件。仅文件名匹配会保持 **未解析**。报告仅保留结构、字段名、样本数量、原始类型统计、媒体格式／尺寸／大小和匹配置信度；不会保留消息正文、姓名、wxid、BLOB、媒体 ID、MD5、媒体文件名或绝对路径。目录权限是 `0700`，报告文件是 `0600`。

## 归档导出与归档查看器

1. 完成第一阶段普通 SQLite 导出后，打开 **完整导出**。
2. 选择普通 SQLite 导出根目录和你本人原始微信账号根目录；两者只读打开。
3. 选择一个**新建或空目录**作为归档目标。完整导出不会合并、覆盖或修复已有归档；若目录非空，导出会拒绝开始。
4. 点击 **分析导出** 查看消息数据库、表和估算消息数。正式入口默认 **全部**；开发验证可选择 100 或 1,000。
5. 点击 **完整导出**。进度会显示消息分类和已复制媒体大小；取消后已完成事务仍是可校验的归档，但再次完整导出请使用新的空目录。
6. 打开 **归档查看器**，选择生成的归档文件夹。查看器只读打开其中的 `archive.sqlite`，不读取微信目录、普通 SQLite 源目录或密钥。

归档包含 `archive.sqlite`、`archive-manifest.json`、`metadata/import-report.json` 和媒体目录。文本、已恢复图片、标准 MP4 视频和未知消息可离线查看；图片原始 DAT、视频原文件和语音原始 Silk 会同时保存。没有本地文件的图片／视频／语音仍保留其消息和 `missing` 媒体记录。macOS 可直接播放归档 MP4。安装兼容的 `silk_v3_decoder` 后，Silk 语音会转换为 WAV 并可在查看器中播放；未安装时仍会保留原始 Silk。

一部分较新微信版本会把撤回通知、位置分享、链接/小程序/引用回复等消息的正文压缩存储。最新构建的 App 内置 Zstandard 运行库，导入时会在有大小限制的内存中尝试解压并显示为文本；源码用户通过 `brew bundle` 准备该库。找不到兼容运行库或解压失败时，消息仍按原始 SQLite 值完整保存，在查看器显示为未识别消息，不影响其余数据的归档。

## 归档查看器：搜索、日期与恢复统计

- **搜索消息内容**：点击查看器工具栏的放大镜图标，输入关键词即可在**所有会话**中搜索消息文本（不仅是会话标题）。点击某条结果会自动切换到对应会话，并跳转、高亮到那条消息附近。
  首次打开归档会在本机 Application Support 建立一个可删除的私有 FTS 搜索索引（目录 `0700`、文件 `0600`）；索引仅含显示搜索所需的消息文本字段，不含来源数据库、原始行或密钥。索引尚未就绪、取消建立或当前 SQLite 不支持 FTS 时，查看器会回退到只读 `LIKE` 搜索。删除该索引只会在下次搜索时自动重建，不影响 Archive。
- **按日期跳转**：点击日历图标，可按当前会话中有消息的年份和月份查看日历。带数字的日期表示消息数量；点击该日期会定位到当天第一条消息附近。
- **双向浏览**：搜索或日期跳转后，顶部可加载更早消息，底部可加载更新消息。两侧均使用稳定的时间线游标，不会因相同时间戳而重复或遗漏。点击“回到最新”恢复最近 100 条消息并定位到末尾。
- **右键操作与快捷键**：文本消息可复制；图片、视频和语音可另存或在 Finder 中显示。`⌘F` 搜索所有消息，`⌘E` 导出当前会话，`⌘J` 回到最新消息。
- **恢复统计**：点击工具栏的统计图标，查看当前归档里消息按类型（文本/图片/视频/语音/未识别）的分布，以及媒体按恢复状态（已解码/仅保留原始文件/缺失等）的分布。统计只读取归档内已聚合的计数，不会读取消息正文或媒体内容。

## 快照与临时明文数据

验证和解密会使用新的本地工作目录：目录权限为 `0700`，快照与明文 SQLite 文件权限为 `0600`。快照复制前后会比较数据库及 `-wal` / `-shm` 的文件集合、大小和修改时间；如果发现变化，该数据库会标为验证/导出失败，并继续处理其余数据库。

这是一项受保护的、尽力保持稳定的文件快照检查，**不是** SQLite transaction-consistent backup。因此必须在微信完全退出后进行真实导入。

如果 `sqlcipher_export`、detach、明文 header 或普通 SQLite 查询验证失败，程序会删除临时明文数据库以及 `-wal`、`-shm`、`-journal` sidecar。成功时，明文数据库从受限暂存目录原子移动到输出目录；输出根目录和新建子目录权限为 `0700`，数据库文件权限为 `0600`。

同名输出文件默认 **Skip**，不会静默覆盖；界面会显示 `Destination exists`。

## 常见问题

取钥、首次安装、终端权限、下载的 App 被拦截、备份与磁盘空间问题，见 [新手常见问题](docs/getting-started.md#权限与常见问题)。下表为桌面导出页面的常见提示。

| 提示 | 处理方式 |
| --- | --- |
| `Key map is invalid.` | 确认选择的是 wx-cli `all_keys.json`，其中每个 `enc_key` 必须是 64 个十六进制字符。 |
| `SQLCipher runtime unavailable. Install with: brew bundle` | 源码用户在项目目录运行 `brew bundle` 后重启应用。SQLCipher 加载器也识别 Intel Homebrew 的 `/usr/local` 路径，这不代表 Intel 取钥已实机验证。 |
| `Database is in use. Please quit WeChat and try again.` | 完全退出微信后重试；不要在同步、备份或写入时验证。 |
| `Key missing` | `all_keys.json` 未包含该数据库的相对路径；检查是否选择了正确的 `db_storage` 根目录。 |
| `Key invalid` | 匹配到了 key，但该 key 不能打开当前数据库；该项会被跳过。 |
| `Destination exists` | 输出目录已有同一相对路径的文件。应用不会覆盖它。 |
| 完整导出提示"普通 SQLite 目录、账号目录、归档目标目录三者中有一个位于另一个内部" | 三个目录必须互不嵌套。常见情况：把归档目标目录建在了普通 SQLite 导出目录里面；换一个完全独立的目标目录（不是它的子目录）即可。 |
| 完整导出提示"目标目录已存在且不为空" | 换一个新建或确实为空的目录；完整导出不会合并或覆盖已有归档。 |

## 开发验证

修改后执行：

```bash
swift build
swift test
git diff --check
```

测试仅使用随机密钥与合成 SQLCipher 数据库；不要将真实聊天记录、数据库、媒体或密钥加入项目。

## 附件保存与重新归档

最新源码创建 v5 归档，查看器可只读打开旧 v1–v4。旧归档不会自动补齐媒体；需用对应账号的普通 SQLite 和原账号媒体目录另建新归档。保持微信退出，原目录只读，输出必须是尚不存在的新目录。

```zsh
swift build -c release --product WeChatArchiveCLI
CLI_DIR="$(swift build -c release --show-bin-path)"
"$CLI_DIR/WeChatArchiveCLI" import-plain \
  --db-dir /绝对路径/普通SQLite根目录 \
  --account-root /绝对路径/微信账号根目录 \
  --archive-output /绝对路径/新的归档目录 \
  --report /绝对路径/新的结果.json
```

不要加 `--limit`，否则只生成样本。此入口无需数据库密钥，故结果 `keyCoverageChecked=false`、`completeCoverage=false`；它只核对归档，不重新证明普通 SQLite 的解密覆盖。图片密钥仍按本地元数据发现；发现失败会保留已关联 DAT，显示占位。

检查结果 `status=completed`、`archiveCreated=true`，再看归档内 `metadata/import-report.json`：`mediaStatusCounts` 区分 `decoded`、`rawArchived`、`imageKeyUnavailable`、`decodeUnsupported`、`missing`、`resolutionConflict`、`resolutionFailed`、`rawCopyFailed` 和 `decodedCopyFailed`。统计通常按变体计数：一条图片可有原图、高清图、缩略图；原始与解码副本也不等于两条消息。`fileRawFound` 表示经大小和内容 MD5 校验后保留的普通文件；`emoticonRawFound` 单独统计原始表情缓存变体。表情通过消息 XML 的 MD5、表情数据库身份及同账号缓存三段关联，保存密文字节与消息关系，目前只显示表情标记，不能声称已经可显示。

图片、视频、语音、普通文件会尽量保留本地可确定关联的内容。同名文件不能单独证明关联。尚未下载、已删除或缺少资源映射的附件无法恢复；表情和转发内嵌附件等未支持结构仍保留消息源字段，不能当作附件全部保存。归档结构与哈希校验通过，也不代表所有媒体都可播放。细节见 [ADR-016](docs/decisions/ADR-016-local-attachment-preservation.md)。

查看器和会话导出只从已成功解码的图片中选择显示变体；有可显示的缩略图时会使用它。只有 WXGF 等暂不支持格式的图片显示占位，原始 DAT 与已恢复的格式字节仍保存在私有归档里。

文件附件在查看器可“在 Finder 中显示”，会话导出的 HTML、JSON 和 Markdown 会复制到 `media/files/`。分享前请检查附件内容；打开归档不会执行附件。

大量小文件建议保存到 APFS 卷。ExFAT 的大分配单元会使实际占用远大于逻辑大小；可用“磁盘工具”在外置盘新建 APFS 稀疏磁盘映像，双击挂载后将新归档保存进去。只新建映像，保留已有盘内容。复制到另一台 Mac 时复制整个映像；打开时先挂载，再选择里面含 `archive.sqlite` 的目录。不要只复制数据库。

### 中断后续跑

只对本次未完成的 v5 归档使用续跑；已完成归档与旧版本会被拒绝。仍用同一普通 SQLite、同一账号目录和同一未完成输出，另选一个新的报告文件，在上面的 `import-plain` 命令末尾加 `--resume`。不能同时用 `--limit`。

续跑会先逐条比对已归档消息的完整源字段，确认账号绑定；来源改变、已保存消息找不到或另一进程正在导入时会停止。只清理该未完成归档内未被数据库引用的受控哈希文件与暂存文件，再跳过已保存消息、补充表情缓存并继续导入。报告的 `messagesImported` 为归档内总数，`messagesSkipped` 为本次跳过的已保存记录。成功仍须通过最终完整校验；不能把中断时已有的目录当作完成。整个归档在完成后才适合迁移。

### 单独校验已有归档

导入已结束但校验进程退出时，不要覆盖归档或把空结果文件当作成功。可用最新 CLI 独立复核，无需重新取钥、复制附件或退出微信：

```zsh
"$CLI_DIR/WeChatArchiveCLI" verify-archive \
  --db-dir /绝对路径/已有归档目录 \
  --report /绝对路径/新的校验结果.json
```

此命令只读检查归档结构、引用附件/头像的 SHA-256 及无孤立媒体文件。成功报告为 `archiveVerified=true`，六项 `archiveChecks` 均为 true；`archiveCreated=false`，因为没有创建新归档。它不证明源数据库解密覆盖或全部本地附件均能关联。也可按个人需要跳过校验，但应保留“最终校验未完成”的记录。
