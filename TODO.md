# 迭代待办（UI 交互 / 消息显示 / 消息恢复）

来源：2026-08-25 项目审核与功能分析。记录已实现之外、值得投入的优化方向，按主题分组，组内按优先级排列。完成的项标注 `[x]` 并注明落地位置；未做的保持 `[ ]`。

## 一、消息恢复处理（adapter 覆盖率）

- [x] **恢复覆盖率报告**：`archive.sqlite` 内消息按 `normalized_type` 分布、媒体按 `status` 分布的聚合统计。
  落地：`WeChatArchiveViewerDatabase.coverageSummary()`（`Sources/Core/ArchiveV1/WeChatArchiveViewer.swift`）+ 查看器工具栏「恢复统计」（`Sources/App/ArchiveViewerView.swift` 的 `CoverageReportSheet`）。测试：`testCoverageSummaryCountsMessagesByTypeAndMediaByStatus`。
- [ ] **拆分 `unknown` 归一化类型**：目前撤回、引用回复、位置、名片、链接分享、红包、转账、拍一拍、语音/视频通话记录、自定义表情 XML 全部落入 `ArchiveV1NormalizedType.unknown`，查看器只显示"[暂不支持的消息]"。优先做**文本降级展示**（从已有 discovery 阶段解析的 XML/payload 提取标题或摘要），不需要一步到位做富媒体渲染。受影响：`Sources/Core/ArchiveV1/WeChatArchiveV1Adapters.swift`、`ArchiveV1NormalizedType`（`WeChatArchiveV1Models.swift`）、`ArchiveViewerView.swift` 的 `content` 分支。
- [ ] **图片 v1/legacy DAT 解码**：`WeChatImageMessageAdapter.decodeV2` 之外，v1/legacy 版本目前标记为 `decodeUnsupported`，只保留原始字节（`WeChatArchiveV1Adapters.swift:130-133`）。需要真实样本验证后补上解码器。
- [ ] **WXGF 图片格式支持**：`decoded.format == .wxgf` 时明确返回 `decodeUnsupported`（`WeChatArchiveV1Adapters.swift:157`），新版表情/图片常用此格式，目前完全不可见。

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

- 2026-08-25：完成本文件第一、二节中标 `[x]` 的两项（恢复覆盖率报告；全文搜索 + 消息媒体缓存）。`swift build` 与 `swift test`（124 项，1 项按环境变量跳过）全部通过。
