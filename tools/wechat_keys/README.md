# 本地取钥与一次性归档

公开代码在本目录；所有本机输出在项目 `wechat/`，已排除在 Git 外。
Rust 扫描器基于 hum0r23/wx-cli 指定提交，来源及许可证见 [NOTICE.md](NOTICE.md) 和 [LICENSE](LICENSE)。

## 一次完成全流程

要求：macOS 15+、完整 Xcode、Python 3.9+、SQLCipher（`brew bundle`）；首次取钥还需 Rust（`brew install rust`）。首次编译可能下载公开 Cargo 依赖，后续使用缓存。运行时不上传用户数据。

请预留临时微信副本、加密快照、解密工作库、归档和媒体复制所需空间。流程预检已知复制量并保留少量余量，最终归档大小依内容而变；空间不足会停止，不保证预检能精确预测全部媒体体积。容量不足时先释放空间，或将整个项目放到容量充足的磁盘。

先在官方微信登录本人有权归档的账号，在项目根目录运行：

```zsh
./scripts/archive-wechat.command --prepare-copy --open-viewer
```

流程依次执行：账号／来源检查 → 构建本地工具 → 独立微信副本 → 登录时捕获与内存扫描 → 第一页 HMAC 验证 → 退出微信 → 私有数据库副本（含 WAL/SHM） → Core 的 SQLCipher 验证／普通 SQLite 导出 → 完整 Archive v1 → 归档校验 → 查看器。

等待临时微信登录页出现，先不要点击进入；在终端按回车安装捕获。看到采集提示后，再点击“进入微信”，打开要归档的聊天。首次取钥需要交互式终端，避免在微信尚未完成启动时附加调试器。采集窗口默认 180 秒，可用 `--capture-seconds 300` 延长。手机登录确认及系统授权需要用户完成，并非完全无人值守。

`--prepare-copy` 明确同意停止当前微信并创建、运行允许调试的副本。**官方微信不重签、不替换**。副本保留原始沙箱、JIT、应用身份和应用组，仅添加 get-task-allow／关闭副本库验证；关闭副本的 Sparkle 自动检查及更新。副本身份变化可能触发重新登录、数据容器授权或功能异常，不保证所有版本都兼容。不关闭 SIP、不自动修改系统隐私权限、不安装后台服务。

终端无法读取微信容器时，用户需要检查实际终端的读取权限，例如“完全磁盘访问”，授权后重开终端。目录权限不能替代进程调试权限。副本未允许调试或被微信更新覆盖、账号变化、目录读取失败、零数据库、空密钥、采集超时都不会被当作成功。

## 缺失数据库

默认严格停止，任何缺失密钥都要检查。只在确认允许排除某个数据库后，逐项指定：

```zsh
./scripts/archive-wechat.command --prepare-copy --open-viewer \
  --allow-missing migrate/unspportmsg.db
```

这只是旧迁移库的示例，不是默认跳过规则。禁止通配符；不能跳过已匹配却验证失败的密钥。报告状态为 `completed_with_allowed_missing`，`completeCoverage` 为 false，并列出未覆盖数据库。

未加载的旧库／冷分片可能没有留在微信内存中。打开聊天或延长采集不保证解决；不能声称全部记录已经完整归档。源文件保持不变。

## 单独导出密钥和复用已有密钥

```zsh
# 此模式明确导出并保留私有 all_keys.json
./scripts/extract-keys.command --prepare-copy

# 已有密钥时跳过微信副本和内存扫描；运行前完全退出微信
./scripts/archive-wechat.command \
  --db-dir /absolute/path/to/db_storage \
  --keys /absolute/path/to/all_keys.json --open-viewer

# 仅作只读验证
python3 tools/wechat_keys/workflow.py validate \
  --db-dir /absolute/path/to/db_storage --keys /absolute/path/to/all_keys.json
```

存在缺失库时，上述命令同样需要逐项明确 `--allow-missing`。默认只识别当前唯一登录账号，不根据修改时间猜测账号。
`--db-dir` 指原始账号的 `db_storage`；完整归档从它的父目录读取媒体。不要把仅含数据库的副本当成账号媒体根目录。

## 输出和清理

每次独立 run-id，不覆盖历史结果：

```text
wechat/keys/<run-id>/all_keys.json       数据库密钥
wechat/snapshots/<run-id>/              加密数据库副本及 sidecar
wechat/databases/<run-id>/              普通 SQLite 工作库
wechat/archives/<run-id>/               完整 Archive v1
wechat/runs/<run-id>/result.json         阶段、数量、缺失相对路径
```

目录 `0700`，密钥／数据库／报告 `0600`。密钥字节不写日志、不放进 argv、不进入归档。
`keys`／`validate` 模式明确保留本次密钥；`archive` 默认在结束或失败时清理本次临时密钥和普通 SQLite，显式 `--keep-keys`／`--keep-databases` 才保留。调用者提供的 `--keys` 原文件不会删除。
候选密钥和本次临时微信副本会清理；加密快照和失败归档保留，仍是私有聊天数据，需用户保护、备份和按需清理。

失败时归档可能不完整，查看报告后用新 run-id 重试，不合并历史输出。
`--limit 100` 只用于小规模验收，正常完整归档不要传。图片、语音等恢复能力和可选解码器沿用原项目，不保证缺少原始媒体时仍能恢复。

Swift CLI 在进程内加载密钥和 SQLCipher，复用原有 Core，不使用含真实密钥字面量的 shell SQL 命令。
只有 `--open-viewer` 设置查看器工作目录及最近归档；保存的是路径，不是密钥或聊天正文。

## 验证

```zsh
swift test
python3 -m unittest discover -s tools/wechat_keys/tests -v
cargo test --locked --manifest-path tools/wechat_keys/native/Cargo.toml
zsh -n scripts/extract-keys.command scripts/archive-wechat.command
git diff --check
```

自动测试只用合成数据。Apple Silicon 本机链路已做真实验收；Intel 参数位置有合成测试，尚无 Intel 实机验收。第一页 HMAC 支持 SQLCipher 4 页格式，不假设旧迁移库也使用同样参数。
