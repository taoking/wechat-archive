# 微信数据库集成

## 状态

本仓库提供 `SQLCipherDatabaseDecryptor`，用于处理用户提供的 64 字符十六进制 SQLCipher 原始密钥。它动态加载本地安装的 SQLCipher runtime（`brew install sqlcipher`／`brew bundle`），因此 runtime 不会复制到仓库中。仓库不包含真实用户数据库或密钥。

解密器对正确密钥验证、错误密钥拒绝、受保护普通 SQLite 导出和来源不变性具有合成端到端覆盖。它不声称兼容某个已发布微信数据库构建；解析仍受 Adapter 门控。

## 当前支持的路径

1. 用户明确选择其有权访问的本地数据库。
2. `DatabaseSnapshotter` 将数据库及可选的 `database-wal` 和 `database-shm` sidecar 复制到新创建的 `0700` 工作目录；复制文件设为 `0600`。
3. `WeChatKeyProvider` 向 `SQLCipherDatabaseDecryptor` 提供本地密钥材料。
4. `WeChatDatabaseDetector` 依据表、列和元数据选择带版本的 Adapter。
5. Adapter 为归档管线输出归一化值。

快照器会在复制前后比较来源文件集合、大小和修改时间。如果数据库、`-wal` 或 `-shm` 在复制期间发生变化（或出现／消失），它会给出“退出微信后重试”的错误，并只删除自身的工作目录。这是受保护、尽力保持稳定的文件快照，而不是事务一致的 SQLite 备份。**验证密钥或导入真实数据库前，请完全退出微信。** 原始来源文件及其 sidecar 绝不会被修改或清理。

## 密钥提供器

- `ManualKeyProvider`：用户输入十六进制密钥；提供器只返回一次，然后释放保存的副本。
- `LocalKeyFileProvider`：读取用户明确选择的小型本地密钥文件；它绝不创建此类文件。
- `EnvironmentKeyProvider`：仅供开发／自动化使用，通过环境变量显式选择；绝不记录或提交它。
- `KeychainKeyProvider`：从 macOS Keychain 读取明确账号条目。未来写入器必须要求单独的“记住此密钥”同意操作。

没有任何提供器会将密钥持久化到 UserDefaults、plist、JSON、SQLite、项目文件或日志。

## Adapter 检测

`WeChatMacV3Adapter` 和 `WeChatMacV4Adapter` 目前只建模识别器。V3 检查具有 `MsgSvrID`、`CreateTime` 和 `StrContent` 的 `Message` 表；V4 检查具有 `local_id`、`timestamp` 和 `payload` 的 `message` 表。这些是有意保守的占位符，并不承诺兼容性。未知 schema 会以 `Unsupported WeChat database version` 失败，而不是被强行解析。

每个生产 Adapter 都必须记录：支持的应用／数据库版本范围、所需 schema 证据、相关文件布局、消息映射、媒体映射、不支持类型和 fixture 来源。fixture 必须是合成数据。

## 临时解密生命周期

解密后的数据库是临时工作数据，不是归档输出。解密器创建一个 `0700` 工作目录，并将生成的普通 SQLite 工件标记为 `0600`。如果解密、导出、detach 或文件头验证失败，它会移除普通 SQLite 数据库及其 `-wal`、`-shm` 和 `-journal` sidecar。解密成功后，调用方必须在解析结束时删除这些工件，除非用户在清晰隐私警告后明确选择“保留解密数据库副本”。绝不要将其放在项目目录或提交到 Git。

## 媒体与消息覆盖范围

归一化模型支持文本、图片、视频、语音、文件、表情、链接、位置、联系人、系统、回复和未知类型。不支持的来源记录必须保留安全的原始／来源元数据并成为 `unknown`；不得变成会造成误导的 `[图片]` 占位。语音解码器与存储分离，因此不支持的音频仍可被保留。
