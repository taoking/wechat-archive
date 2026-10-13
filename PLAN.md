# WeChat Archive 开发计划

## ExFAT 归档查看失败修复（2026-10-13）

- [x] 阅读 README、PLAN、开发说明与用户提供的 AGENTS.md；只读检查指定归档。
- [x] 复现 macOS SQLite 在 ExFAT 上读取 WAL 归档时的 SQLITE_IOERR_WRITE（778）；确认空 WAL 下 immutable 读取成功。
- [x] 统一归档只读连接：普通读取失败且 WAL／回滚日志不存在或为空时使用 immutable；非空 WAL 保持正常读取，禁止兼容回退。
- [x] 优化会话分页，避免为首页排序全部消息正文；补充合成回归测试与明确错误提示。
- [x] 运行完整 Core 测试、构建与差异检查；重新启动查看器并实机确认目录打开及消息浏览。

风险边界：immutable 会跳过锁与变更检测，仅用于一次性封存且 WAL／回滚日志不存在或为空的归档；不绕过非空日志、不修改真实归档。真实数据验证只输出统计与耗时，不将聊天正文写入测试或日志。当前仅确认基本结构与计数可读，未完成真实归档全部媒体哈希及整库完整性验证。

兼容方式依据：[SQLite URI immutable 文档](https://sqlite.org/uri.html)、[WAL 只读数据库说明](https://sqlite.org/wal.html)。新增测试覆盖兼容回退、中文／特殊字符路径、归档与辅助文件保持不变、非空 WAL 可见性、非空回滚日志拒绝、其他错误不掩盖、会话分页与同时间消息排序。

验证命令与结果：`swift test` 退出 0（152 项，150 项通过、2 项可选实机测试跳过）；`swift build` 退出 0；`git diff --check` 通过；`./scripts/run-app.sh` 退出 0，已重建签名并启动修复版。忽略目录内的本机只读探针确认：首屏 100 会话约 6 秒，第二页 100 会话无重复，最新 100 消息可读，数据库大小与修改时间不变。界面验收已成功打开指定归档并切换会话，无读取失败提示。本次按用户要求提交并推送，仅包含公开代码、合成测试与说明，不包含真实归档、密钥或本机探针；推送结果在对话中核对。

## 新手说明与搜索信息（2026-10-13）

- [x] 阅读 README、PLAN、已有使用说明及用户提供的 AGENTS.md；核对 GitHub 下载包、源码入口和当前参数。
- [x] 补充首页项目定位、适用范围、下载选择、使用步骤及中英文搜索关键词。
- [x] 添加新手指南，说明取钥时机、已有密钥、成功判断、输出备份、权限和常见问题；同步中英文使用说明。
- [x] 检查 Markdown 本地链接、命令帮助、文档与实现一致性和提交范围。
- [x] 更新 GitHub 中英文简介与 18 个 Topics，包括 wechat、wechat-export、wechat-backup、sqlcipher、macos、key-extraction。
- [x] 提交并推送新手文档，确认远端提交及 CI 运行入口。

本次只修改公开文档和仓库搜索信息，不运行真实聊天完整归档，不提交本机密钥、数据库或媒体。GitHub v0.3.0 已有 Apple Silicon App 下载，但不含最新源码中的取钥模块；新手说明须明确区分。

提交前检查：`./scripts/archive-wechat.command --help`、`./scripts/extract-keys.command --help` 均退出 0；`zsh -n scripts/run-app.sh scripts/build-app.sh scripts/archive-wechat.command scripts/extract-keys.command` 通过；一次性 `python3` 文档检查核对 6 份 Markdown 的 45 个链接（本地目标／锚点有效）、23 个代码块闭合，以及 22 个 shell 示例的语法和脚本路径，均通过；`git diff --check` 通过。核对下载包使用 GitHub Release 元数据，未实际下载安装包；本次没有重新执行真实取钥或真实聊天完整归档。

发布记录：新手文档提交 [205e58c](https://github.com/taoking/wechat-archive/commit/205e58cc3d58563deea26386507a4a4f759e02ad) 已推送并核对远端 main；GitHub 简介与 18 个 Topics 已回读确认。该提交的自动构建／测试结果见 [GitHub CI](https://github.com/taoking/wechat-archive/actions/runs/38358185701)。

## 密钥获取与一次性归档集成（2026-10-13）

- [x] 阅读 README、开发／隐私／安全说明与现有归档 API，确认远端 main 未发生变化。
- [x] 确定独立模块边界：公开代码放 tools/wechat_keys；本机密钥、微信副本、数据库和归档放忽略的 wechat/。
- [x] 集成基于 hum0r23/wx-cli 指定提交的 macOS 扫描器，保留 Apache-2.0 许可证和来源，加入显式账号／进程边界、HMAC 校验与无空结果行为。
- [x] 集成临时副本、调试权限、登录页就绪确认、登录时捕获、退出与清理，避免修改官方微信和全局系统授权。
- [x] 增加调用现有 Core 的 CLI：密钥验证 → 普通 SQLite 导出 → 完整 Archive v1，缺失数据库必须逐项显式允许。
- [x] 添加单命令入口、合成数据测试、CI、使用说明及隐私边界说明。
- [x] 运行完整测试、已有密钥复用与新入口实机取钥只读验收，核查提交内容无私有数据。
- [x] 提交并推送到 taoking/wechat-archive，核对远端提交；功能提交 4769633 的 GitHub CI 全部通过。

当前测试：Swift 148 项（2 项可选实机测试跳过）、Python/CLI 29 项、Rust 13 项均通过；合成加密数据库已完成解密与完整 Archive v1 验收，成功／失败均覆盖临时密钥清理。已有密钥模式实测验证 32 个数据库有效，1 个缺失并明确报告。取钥使用独立终端控制 LLDB，逐步确认恢复／分离与退出；恢复已安装断点及其单步事件、调试器 SIGSTOP；其他异常保持停止。加入磁盘空间预检；新入口 Apple Silicon + 微信 4.1.15 实机验收导出并验证 32 个数据库密钥，1 个旧迁移库缺失并通过精确允许列表明确报告。未执行真实聊天内容的完整归档，完整归档端到端验收使用合成数据。

发布验证：[功能提交 4769633 的 CI](https://github.com/taoking/wechat-archive/actions/runs/38355987201) 已通过；本次上传仅含代码、文档、许可证及合成测试，不含 wechat/ 运行数据。

已有链路证据：Apple Silicon 本机登录时捕获与第一页 HMAC 匹配成功；33 个加密数据库中 32 个通过 SQLCipher 只读结构验证，1 个未被当前微信加载的旧迁移数据库没有密钥。这个结果不等于所有版本、所有数据库均可成功。复用流程默认严格停止，允许缺失必须显式指定相对数据库路径。

## 第一阶段 — 归档基础（已实现）

- 稳定的 Archive v1 模型及 JSON/NDJSON 序列化。
- 会话／年份 NDJSON 分区、SHA-256 媒体内容寻址、manifest 与校验和。
- 带版本 SQLite schema、参数化写入、FTS5 搜索、导入历史和确定性的增量去重。
- 离线 HTML/CSV/JSON/NDJSON 导出及归档验证。
- SwiftUI 导航壳和纯本地导入／密钥体验。

## 第二阶段 — 普通 SQLite Schema 发现（已实现）

- 递归发现第一阶段普通 SQLite 导出，以只读方式检查 schema 并生成受保护的 JSON/Markdown 报告。
- 根据结构信号分类可能的消息、联系人、会话、群聊、媒体、索引和配置数据库；按仅结构 SHA-256 指纹将相同 schema 分组。
- 不读取数据库值、不解析消息、不导出聊天内容。

## 第三阶段 A — 消息与媒体链接发现（已实现）

- 读取第二阶段结构报告，并让用户选择真实消息表候选项。
- 从所选普通 SQLite 表最多读取 500 行，保留源 SQLite 存储类型，并推断字段映射、时间单位和原始类型分布。
- 仅提取结构化 XML/JSON/BLOB 证据，以有上限、可取消的方式扫描另行选择的本地媒体根目录；只有证据充分时才验证媒体链接。
- 写入脱敏的本地分析报告；不创建或修改 Archive v1 数据。

## 第三阶段 B — 首个真实消息 Adapter

- 选择已确认的消息 schema 组，并为归一化消息实现最小化、基于 fixture 的 Adapter。
- 增加带预览、进度、取消和可恢复来源复制的 JSON/NDJSON 归档导入 UI。
- 增加带显式字段映射的 CSV/TXT/HTML Adapter，而不是启发式地丢失数据。

## 第三阶段 — 归档浏览器

- 从索引以每页 100–500 项读取会话和联系人。
- 增加聊天时间线、跳转到消息、日期导航、媒体图库、Quick Look、AVKit 和语音解码器接口。
- 实现真实的仪表盘统计与健康状态 UI。

## 第四阶段 — 导出与生命周期

- 为 HTML 导出增加媒体复制选项和确定性的导出文件夹。
- 增加 OpenXML DOCX 导出器和按年份分割的 PDF 导出器。
- 增加 Archive v1→v2 迁移运行器、索引重建工具和备份提醒。

## 非目标

- 不提供服务端导入、远程密钥发现、账号访问、云同步或分析。
- 不解析当前 macOS 用户无权访问的数据。
