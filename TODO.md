# 迭代待办（UI 交互 / 消息显示 / 消息恢复）

来源：2026-08-25 项目审核与功能分析。记录已实现之外、值得投入的优化方向，按主题分组，组内按优先级排列。完成的项标注 `[x]` 并注明落地位置；未做的保持 `[ ]`。

## 一、消息恢复处理（adapter 覆盖率）

- [x] **恢复覆盖率报告**：`archive.sqlite` 内消息按 `normalized_type` 分布、媒体按 `status` 分布的聚合统计。
  落地：`WeChatArchiveViewerDatabase.coverageSummary()`（`Sources/Core/ArchiveV1/WeChatArchiveViewer.swift`）+ 查看器工具栏「恢复统计」（`Sources/App/ArchiveViewerView.swift` 的 `CoverageReportSheet`）。测试：`testCoverageSummaryCountsMessagesByTypeAndMediaByStatus`。
- [x] **拆分 `unknown` 归一化类型（高置信度部分）**：2026-08-25 对照一份真实归档做了结构性排查（只读取字段名/标签名/字节长度，未读取实际聊天内容）才发现：这个微信版本把 `message_content` 用 **Zstandard 压缩存储**，不是明文列，这才是这批消息此前完全无法识别的根因——不只是"没写 adapter"。
  落地：
  - `ZstdPayloadDecompressor`（`WeChatArchiveV1Adapters.swift`）：通过本机 `zstd` CLI 解压（已加入 `Brewfile`）。**Apple 系统 `Compression` 框架不支持 zstd**（已对照 SDK `compression.h` 确认，最初以为"零依赖"是错的），所以这里复用了 Silk 语音解码器已有的"可选外部工具，缺失时优雅降级"边界，而不是新增一个真正的第三方 package 依赖。
  - `WeChatMessageXMLDocument`：最小化、禁用外部实体解析的路径式 XML 读取器。
  - `WeChatCompressedTextMessageAdapter`：解压后按 `raw_local_type` 低 32 位分发——`10000`（系统消息，目前只认 `revokemsg` 撤回子类型）、`48`（位置，取 `poiname`/`label`）、`49`（app 消息，通用提取 `appmsg/title` + `appmsg/refermsg`，覆盖链接分享/小程序/视频号/红包/转账/引用回复等全部子类型，不局限于人工验证过树形结构的那两种）；`1`（纯文本）经 `"{wxid}:\n"` 前缀剥离后按普通文本处理。无法识别的情况一律返回 nil，消息保持原有 `unknown`，不会误判。
  - 接入点：`WeChatArchiveV1Importer.process()`（原来 image/video/voice 判断之后、落到 `unknown` 之前）。
  - 测试：`testCompressedTextMessageAdapterDecodesRevokeLocationAndQuoteReplyFromZstdXML`、`testCompressedTextMessageAdapterRecoversGroupTextAndFallsThroughOnUnrecognizedTypes`、`testZstdPayloadDecompressorRejectsNonZstdAndOversizedInput`，以及一个只读、不打印任何消息内容的真实归档验收测试 `testOptionalCompressedTextMessageAdapterCoverageAgainstRealArchive`（`WECHAT_ARCHIVE_REAL_ROOT` 触发）。
  - **真实验证结果**（这份归档）：11525 条 unknown 中恢复 **7244 条（62.8%）**——群聊文本 622/622、位置 100/100、app 消息 6472/6495（99.6%，证实了"只认 title/refermsg"的通用兜底策略在真实数据上覆盖面很好）、系统消息 50/572（8.7%，只有 revoke 子类型被识别，其余 sysmsg 子类型——拍一拍/群公告变更等——仍保持 unknown，是有意保守，不是 bug）。全库 unknown 占比从 21.5% 降到约 8.0%。
  - **仍未做（下面单独列出）**：自定义表情/贴图（type 47，`<msg><emoji.../></msg>` 已能解析出结构，但内容是远程 CDN 图，跟 WXGF 一样是"能分类、不能离线渲染"）；`sysmsg` 除 revoke 外的其余子类型（约 522 条）；引用回复中 `refermsg/content` 本身如果是非文本消息（图片/视频引用）时的展示细化。
  - **打包注意**：`build-app.sh` 目前不bundle `zstd`（跟 Silk 解码器一样，是有意的可选外部工具边界，README/DEVELOPMENT.md 已补充说明），意味着没跑过 `brew bundle` 的机器上，这部分消息会保持 unknown 而不是报错——行为上是安全的，但覆盖率会低于本机验证的 62.8%。
- [ ] **图片 v1/legacy DAT 解码**：`WeChatImageMessageAdapter.decodeV2` 之外，v1/legacy 版本目前标记为 `decodeUnsupported`，只保留原始字节（`WeChatArchiveV1Adapters.swift`）。需要真实样本验证后补上解码器。
- [ ] **WXGF 图片格式支持**：`decoded.format == .wxgf` 时明确返回 `decodeUnsupported`，新版表情/图片常用此格式，目前完全不可见。
- [ ] **自定义表情/贴图内容**（type 47）：结构已能解析（`<emoji md5="" cdnurl=""/>`），但目前没有落地成 adapter；即使落地，内容本身是远程 CDN 资源，离线场景下最多只能显示"[表情]"占位，不能真正渲染——除非本机能找到微信自己缓存的表情文件（另一个媒体定位任务，类似图片/视频的 hardlink 定位）。
- [ ] **`sysmsg` 其余子类型**（约占系统消息的 91%）：目前只认 `type="revokemsg"`；拍一拍、群公告变更、入群退群提示等其余子类型的真实 XML 结构还没有验证过，需要重复这次的"结构探测 → 真实数据验证 → 落地"流程。

## 二、消息显示 / UI 交互

- [x] **全文搜索（消息正文）**：会话搜索此前只搜标题（`searchConversationPage` 明确"只搜 conversation 标题，从不搜消息正文"）。新增跨会话消息文本搜索，点击结果可直接跳转到该消息并高亮定位。
  落地：`WeChatArchiveViewerDatabase.searchMessagePage` / `messageOffset` / `messagePage(offset:)`（`WeChatArchiveViewer.swift`）+ 工具栏「搜索消息内容」入口（`MessageSearchSheet`，`ArchiveViewerView.swift`）+ 跳转态处理（`TimelineScrollInstruction.jumpTo`、`TimelinePagingState.replaceCentered`，`Sources/Core/ConversationExport/ConversationExportModels.swift`）。测试：`testSearchMessagePageFindsTextAcrossConversationsAndComputesSnippet`、`testMessageOffsetMatchesAscendingTimelinePosition`。
  已知限制：跳转到搜索结果后，当前只支持继续向更早方向翻页或点「回到最新」整体重置；不支持跳转位置向"更新"方向连续加载（双向分页），因为窗口不再是尾部锚定的偏移语义。见下方「双向分页」待办。
- [x] **消息图片/视频缩略图缓存**：`imageContent`/`videoContent`/图片预览此前每次渲染都同步 `NSImage(contentsOf:)` 重新解码，图片多的会话滚动容易卡顿；头像已有 `ArchiveAvatarImageCache` 但消息媒体没有。
  落地：`ArchiveMediaImageCache`（`ArchiveViewerView.swift`），按归档内相对路径缓存解码后的 `NSImage`。
- [ ] **日期跳转导航**：PLAN.md 第三阶段计划中的"日期导航"未落地，翻看历史消息只能靠"加载更早的消息"逐页翻。
- [ ] **双向分页（跳转后继续向新消息方向加载）**：本次搜索跳转只实现了"以命中消息为中心加载一个窗口"，若想在窗口内继续往更新方向翻页，需要扩展 `TimelinePagingState`/`WeChatArchiveViewerDatabase` 支持双向 `hasMoreOlder`/`hasMoreNewer` 语义（当前 `hasMore` 只有单一方向含义，`messagePage(offset:)`/`recentMessagePage(offset:)` 的偏移量基准不同，直接复用会有语义混淆，需要专门设计）。
- [ ] **聊天内查找定位（Cmd+F 高亮跳转）**：已被"全文搜索"覆盖了跨会话场景；如果需要"当前会话内查找并逐条跳转"（类似浏览器 Cmd+F 的上一条/下一条），还可以在现有搜索基础上加一个"仅搜当前会话 + 上一条/下一条"的轻量模式。
- [ ] **右键菜单**：复制文本、在 Finder 中显示媒体文件、保存图片/视频到别处。目前完全没有上下文菜单。
- [ ] **多选批量导出**：目前导出只能整会话导出（`ConversationExportSheet`），无法勾选部分消息导出。
- [ ] **未支持消息的原始类型提示**：即使不做完整 adapter，也可以先把 `raw_local_type` 数值显示出来，方便用户/开发者判断是哪类消息，比"暂不支持"更有信息量。

## 三、非目标外但值得记录的观察（不改变现有边界）

- 应用签名目前是 ad-hoc 本地签名，未做 Developer ID / notarization，分发给他人会被 Gatekeeper 拦截（README/DEVELOPMENT.md 已知）。
- `Sources/Core/Statistics.swift` 的 `ArchiveStatisticsCalculator` 目前只在自己的测试里被引用，未接入任何 UI 路径；`Sources/Core/SQLiteArchiveIndex.swift` 里的 `message_search` FTS5 虚表也属于另一条未接入查看器的通用 Archive 索引管线（`Import.swift`/`SQLiteArchiveIndex.swift`），与本次查看器新增的 LIKE 搜索是两套互相独立的代码路径——如果后续要统一，需要单独设计（可能是把 FTS5 迁移进 `WeChatArchiveV1Database` schema，涉及 schema version bump 和迁移工具，属于 PLAN.md 第四阶段范畴）。

## 执行记录

- 2026-08-25（上午）：完成第一、二节中最初标 `[x]` 的两项（恢复覆盖率报告；全文搜索 + 消息媒体缓存）。`swift build` 与 `swift test`（124 项，1 项按环境变量跳过）全部通过。
- 2026-08-25（下午）：对照真实归档排查 `unknown` 根因，发现 zstd 压缩问题；落地群聊文本/系统撤回/位置/app 消息（含引用回复）的高置信度恢复。`swift build`/`swift test`（128 项，2 项按环境变量跳过）全部通过；真实归档验收测试显示 unknown 占比从 21.5% 降到约 8.0%。
