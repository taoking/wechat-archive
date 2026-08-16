# 使用说明

WeChat Archive 是仅在本机运行的 macOS 归档工具。当前可验证用户主动选择的 SQLCipher 数据库密钥；真实微信 schema 的消息解析仍需后续 Adapter 支持，因此未知数据库不会被猜测或强制解析。

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
   swift run WeChatArchive
   ```

   也可以用 Xcode 打开 `Package.swift`，选择 `WeChatArchive` executable 后运行。

## 验证本地数据库密钥

1. **完全退出微信。** 不要只关闭窗口；请从菜单退出并确认没有继续运行。这样能避免遗漏尚未 checkpoint 的 WAL 数据。
2. 在应用的 **Imports** 页面选择你本人有权访问的本地数据库。
3. 输入 **64 个十六进制字符**的 SQLCipher raw key（32 字节）。输入框不会接受或显示密钥的日志、文件或归档副本。
4. 保持“**验证后清除密钥**”开启（默认）。验证完成后，无论成功或失败，输入框都会清空；关闭此选项只会暂时保留 UI 输入，不会把密钥保存到 Keychain、文件、日志或归档。
5. 点击 **Validate Key**。大数据库的复制和验证会在后台执行，界面会显示 `Validating…`，不会阻塞窗口。

成功时，应用只会验证受保护的本地文件快照中的密钥。原始数据库及其 `-wal` / `-shm` 文件不会被写入、重命名或清理。

## 快照与临时明文数据

验证和解密会使用新的本地工作目录：目录权限为 `0700`，快照与明文 SQLite 文件权限为 `0600`。快照复制前后会比较数据库及 `-wal` / `-shm` 的文件集合、大小和修改时间；如果发现变化，操作会终止并提示退出微信后重试。

这是一项受保护的、尽力保持稳定的文件快照检查，**不是** SQLite transaction-consistent backup。因此必须在微信完全退出后进行真实导入。

如果 `sqlcipher_export`、detach 或明文 header 验证失败，程序会删除临时明文数据库以及 `-wal`、`-shm`、`-journal` sidecar。成功解密后的明文仍属于临时敏感数据，调用方在完成解析后必须删除它们；当前 UI 只提供密钥验证，不会保留明文数据库。

## 常见问题

| 提示 | 处理方式 |
| --- | --- |
| `Expected a 64-character hexadecimal key.` | 使用恰好 64 个十六进制字符的 raw key；不要粘贴空格、前缀或密码短语。 |
| `SQLCipher runtime unavailable. Install with: brew bundle` | 在项目目录运行 `brew bundle`，然后重新启动应用。Intel Mac 也支持 `/usr/local` 下的 Homebrew SQLCipher。 |
| `Database is in use. Please quit WeChat and try again.` | 完全退出微信后重试；不要在同步、备份或写入时验证。 |
| `Database decryption failed` | 密钥可能不正确，或该数据库使用了尚未配置的 SQLCipher 参数/格式。不会泄露数据库路径、内容或密钥。 |

## 开发验证

修改后执行：

```bash
swift build
swift test
git diff --check
```

测试仅使用随机密钥与合成 SQLCipher 数据库；不要将真实聊天记录、数据库、媒体或密钥加入项目。
