# ADR-016：本地附件保留、文件消息与覆盖报告

- 状态：已接受
- 日期：2026-10-13

## 问题与决策

完整消息数量并不能证明附件已保存。图片密钥发现异常曾使整个图片适配器退出，连已找到的 DAT 原文件也被遗漏；旧报告还把媒体复制失败合并为解码失败。

1. 图片解码与原始保留分开处理。无密钥、不支持的 DAT 和解码失败均尽量保存原始文件。不能读取或复制时写入明确状态，不把异常冒充本地缺失。
2. 视频和文件流式复制字节到归档自己的新文件，校验大小与 SHA-256，不继承源文件的 ACL、只读权限或扩展属性。
3. 同一媒体类别目录内以 SHA-256 加扩展名命名，复用已有且校验通过的内容。消息关系保持独立；回滚不得删除复用文件。校验器按路径验证一次，同时拒绝同路径的矛盾摘要。
4. 保持现有 message_resource 的精确关联及冲突拒绝规则，按本次导入缓存资源库、会话摘要与图片密钥候选；密钥只存在内存中。
5. 对 low32=49、XML appmsg/type=6 的文件消息，解析标题、大小和内容 MD5；仅在所选账号 msg/file/YYYY-MM 中查找普通文件。必须大小和 MD5 同时一致；同名、扩展名或远程下载地址不足以关联。不访问网络、不执行附件、不跟随符号链接。
6. 消息正文统一接受 TEXT、UTF-8 BLOB 和有界 zstd BLOB；通过 Zstandard 稳定 API 在内存解压，避免为每条消息创建进程与明文临时文件。库发现仅使用 App 内置与 Homebrew 固定路径，缺少库时保留 CLI 回退；XML 禁止外部实体声明。结构化 XML 子类型优先于高位类型标签，原始字段仍完整保留。
7. 新归档 schema 为 v5，新增 file 类型及 resolutionFailed 状态；查看器继续只读打开旧 v1–v4。文件可在 Finder 查看，并随 HTML/JSON/Markdown 导出；调用方可通过 includeFiles 排除。
8. metadata/import-report.json 按媒体类型与状态统计。missing 是变体数量，不能理解为丢失消息数量；decoded 与原始保留也可指同一变体。import-plain 复用已有普通 SQLite，报告明确 keyCoverageChecked=false，不声称重新验证了数据库密钥。

9. 每 500 条源消息提交一次数据库批次，消息插入使用 savepoint 保持原子性；取消会提交已处理消息，最终校验后才报告完成。保留 SQLite 原有同步策略，避免对外置盘逐条提交的成本。

## 覆盖边界

“完整导入”指读取所选普通 SQLite 中所有已支持消息表。媒体仅保留能由当前结构确定关联的本地文件；不会按时间或文件名猜测未关联缓存。未下载、已删除、资源映射缺失、表情专有格式、转发消息内嵌附件及未支持结构仍可能只有原始消息字段或占位。未知消息的来源字段和 BLOB 继续保存，供以后重新解析。不得宣传所有附件都恢复或所有媒体可播放。

归档包含原始 DAT/Silk 和可显示的派生副本，逻辑大小可能超过原始媒体的单份大小。ExFAT 的大分配单元会放大小文件的磁盘占用；推荐 APFS，或外置盘上的独立 APFS 稀疏映像。不能格式化用户已有磁盘。

## 参考与实现来源

本次独立实现，没有复制第三方源代码或引入网络依赖。Zstandard 是既有 Homebrew 依赖，新增内存调用并随 App 打包其库与 BSD 许可证。参考以下公开结构和算法，并以本机只读结构、合成测试验证关联约束：

- [wxcli 资源关联实现（固定提交）](https://github.com/hydewww/wxcli/blob/08af894594b4afd468e23e17dbd783f15403f13b/src/attachment/resolver.rs)：ChatName2Id 的 rowid 与 MessageResourceInfo 字段关联。
- [greenbubbles 数据库结构说明](https://github.com/bojieli/greenbubbles/blob/main/docs/WECHAT_DATABASE_FORMAT.md)：消息与资源结构参考。
- [wechat-decrypt macOS 图片密钥发现](https://github.com/ylytdeng/wechat-decrypt/blob/main/find_image_key_macos.py)：kvcomm 元数据推导参考，项目既有 Swift 实现保持内存边界。

- [Zstandard 官方手册](https://facebook.github.io/zstd/zstd_manual.html)：稳定 API、帧大小与解码输出界限。

## 验证

合成测试覆盖取钥抛错时保留 DAT、内容去重与回滚、文件大小/MD5/路径/符号链接拒绝、只读源复制、TEXT/BLOB 解析、文件在三种格式导出及排除。CLI 验收验证普通 SQLite 不变、已有归档不覆盖以及不误报密钥覆盖。
