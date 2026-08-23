# ADR-012：将 Silk 解码保持在经审查的外部解码器边界之后

## 状态

已接受

## 日期

2026-08-22

## 背景

Archive v2 可逐字节保留已观察到的微信 Silk 语音数据，但 macOS 不能原生播放它。即使转换无法运行，归档也必须保留原始 Silk；成功导出则应包含供只读查看器使用的可移植 WAV。

已审查的 `kn007/silk-v3-decoder` 项目采用 MIT 许可证，其包含的 Skype Silk SDK header 带有 BSD 风格再分发许可证。该项目是大型 C codec 分发；若未完成源码和构建审计就复制到 Swift Core，会增加显著维护和供应链边界。仅 GPL 的 Silk wrapper 已被拒绝。

## 决策

在 Core 定义 `VoiceDecoder` protocol 和 `WAVWriter`。初始 `SilkProcessVoiceDecoder` 使用受保护临时文件和固定、非 shell 参数调用显式安装或 App 内置的 `silk_v3_decoder` 可执行文件。它在调用前验证 Silk，只接受普通、非符号链接的可执行文件，限制 PCM 输出，且绝不记录来源音频或解码器输出。

如果没有兼容可执行文件，导入器仍会归档原始 Silk 并记录 `decodeUnsupported`；绝不丢弃消息。成功解码的结果会转换为有符号 16 位 little-endian WAV，并与原始 Silk 一同存入私有归档。

本阶段不分发任何第三方 codec 源码或二进制。`THIRD_PARTY_NOTICES.md` 记录可选解码器归属；未来若打包解码器，必须保留完整 MIT 项目声明和 Skype BSD 风格声明，并以精确构建来源决策替代本 ADR。

## 考虑过的替代方案

### 将 GPL Silk wrapper 复制到 Core

- 优点：一步集成。
- 缺点：存在不兼容的分发义务。
- 拒绝原因：项目不得在没有明确许可证策略时引入 GPL codec 代码。

### 调用任意 `ffmpeg`

- 优点：常见已安装工具。
- 缺点：本地 FFmpeg 构建不公开 Silk 解码器，且任意 PATH 解析不是可靠或可审计的 codec 边界。
- 拒绝原因：它本身无法解码已观察到的来源数据。

### 立即打包完整 C SDK

- 优点：不需要外部可执行文件。
- 缺点：大型源码引入需要完整的源码／构建／许可证审计。
- 延后原因：在审查此项工作时保持 Swift 归档契约稳定。

## 后果

- 兼容且获批准的解码器存在时，语音播放可用。
- 每种结果中原始 Silk 都是无损事实来源。
- 查看器只使用已归档 WAV 播放，绝不回到微信数据。
