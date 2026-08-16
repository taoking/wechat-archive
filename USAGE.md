# 使用说明

WeChat Archive 第一阶段只做一件事：读取用户选择的 wx-cli `all_keys.json`，按数据库**相对路径**匹配 `enc_key`，将对应的 SQLCipher 数据库导出为可由普通 `sqlite3` 或 SQLite GUI 打开的 SQLite 数据库。本阶段不解析聊天消息、联系人、媒体或数据库 schema。

## 准备环境

1. 安装完整 Xcode（Command Line Tools 不足以运行 SwiftUI 应用）。
2. 安装 Homebrew SQLCipher 运行库：

   ```bash
   brew bundle
   ```

   或者：

   ```bash
   brew install sqlcipher
   ```

3. 在项目目录运行：

   ```bash
   ./scripts/run-app.sh
   ```

   该脚本将 Swift 可执行文件放入本地 `.app` bundle 后启动，使 macOS 正确激活窗口和文件选择面板。不要用裸的 `swift run WeChatArchive` 进行交互式使用；它不是注册的 `.app` bundle，可能导致 Open 面板无法获得键盘焦点。

   也可以用 Xcode 打开 `Package.swift`，选择 `WeChatArchive` executable 后运行。

## 批量导出为普通 SQLite

1. **完全退出微信。** 不要只关闭窗口；请从菜单退出并确认没有继续运行。这样能避免遗漏尚未 checkpoint 的 WAL 数据。
2. 打开应用的 **Database Export** 页面。
3. 点击 **Choose Folder**，选择微信 `db_storage` 根目录。若 macOS 文件选择器无法进入容器目录，可在同一行输入完整的绝对路径（支持 `~`），然后点击 **Use Path**；相对路径、普通文件和不存在的目录会被拒绝。
4. 点击 **Use ~/.wx-cli/all_keys.json**；如果 key map 位于其他位置，点击 **Choose File** 选择它。
5. 点击 **Scan**。应用递归查找 `*.db`，将例如 `contact/contact.db` 作为相对路径与 `all_keys.json` 匹配。不会仅按文件名匹配。
6. 点击 **Validate All**。每个已匹配的数据库会依次验证；某一项失败不会阻止其他项继续。
7. 点击 **Choose Export Folder** 选择输出目录，然后点击 **Export Databases**。
8. 使用普通 SQLite 工具打开结果，例如：

   ```bash
   sqlite3 /path/to/Export/contact/contact.db '.tables'
   ```

`all_keys.json` 只会在内存中读取；不会复制到导出目录、写入日志、数据库、普通文件或 Git。密钥不会作为命令行参数传递。导出完成后，应用会丢弃会话中保存的匹配密钥；如需再次导出，请重新 Scan 和 Validate。

## 快照与临时明文数据

验证和解密会使用新的本地工作目录：目录权限为 `0700`，快照与明文 SQLite 文件权限为 `0600`。快照复制前后会比较数据库及 `-wal` / `-shm` 的文件集合、大小和修改时间；如果发现变化，该数据库会标为验证/导出失败，并继续处理其余数据库。

这是一项受保护的、尽力保持稳定的文件快照检查，**不是** SQLite transaction-consistent backup。因此必须在微信完全退出后进行真实导入。

如果 `sqlcipher_export`、detach、明文 header 或普通 SQLite 查询验证失败，程序会删除临时明文数据库以及 `-wal`、`-shm`、`-journal` sidecar。成功时，明文数据库从受限暂存目录原子移动到输出目录；输出根目录和新建子目录权限为 `0700`，数据库文件权限为 `0600`。

同名输出文件默认 **Skip**，不会静默覆盖；界面会显示 `Destination exists`。

## 常见问题

| 提示 | 处理方式 |
| --- | --- |
| `Key map is invalid.` | 确认选择的是 wx-cli `all_keys.json`，其中每个 `enc_key` 必须是 64 个十六进制字符。 |
| `SQLCipher runtime unavailable. Install with: brew bundle` | 在项目目录运行 `brew bundle`，然后重新启动应用。Intel Mac 也支持 `/usr/local` 下的 Homebrew SQLCipher。 |
| `Database is in use. Please quit WeChat and try again.` | 完全退出微信后重试；不要在同步、备份或写入时验证。 |
| `Key missing` | `all_keys.json` 未包含该数据库的相对路径；检查是否选择了正确的 `db_storage` 根目录。 |
| `Key invalid` | 匹配到了 key，但该 key 不能打开当前数据库；该项会被跳过。 |
| `Destination exists` | 输出目录已有同一相对路径的文件。应用不会覆盖它。 |

## 开发验证

修改后执行：

```bash
swift build
swift test
git diff --check
```

测试仅使用随机密钥与合成 SQLCipher 数据库；不要将真实聊天记录、数据库、媒体或密钥加入项目。
