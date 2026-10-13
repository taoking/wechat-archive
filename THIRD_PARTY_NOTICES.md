# 第三方声明

## 本地密钥获取模块

`tools/wechat_keys/native/src/scanner.rs` 衍生自 [hum0r23/wx-cli](https://github.com/hum0r23/wx-cli) 的 macOS 扫描器，采用 Apache License 2.0。固定提交、修改范围及完整许可证见 [NOTICE](tools/wechat_keys/NOTICE.md) 和 [LICENSE](tools/wechat_keys/LICENSE)。此工具由用户本机单独编译；不随 App 分发微信、真实密钥或数据库。

## 随 App 打包的 SQLCipher runtime

macOS Release App 内置了本地数据库导出所需的 SQLCipher runtime。SQLCipher 以 BSD 3-Clause License 发布。随包二进制的完整许可证文本位于 App 内：`Contents/Resources/ThirdPartyNotices/SQLCipher-LICENSE.txt`。

Release App 同时内置对应的 OpenSSL `libcrypto` runtime，采用 Apache License 2.0。完整许可证文本与 SQLCipher 声明一同放在 App bundle 内。

## 可选 Silk 解码器

语音转换可使用单独安装的 [kn007/silk-v3-decoder](https://github.com/kn007/silk-v3-decoder) 项目的 `silk_v3_decoder` 可执行文件。该项目采用 MIT 许可证；其 SDK 衍生的 Silk 源文件带有上游 Skype BSD 风格再分发声明，其中包含专利免责声明。

本仓库不包含、编译或再分发该解码器的源代码或二进制文件。操作者安装可选解码器后，应自行保留上游声明并遵守其许可证。

## 随 App 打包的 Zstandard runtime

压缩消息通过 [Zstandard 官方稳定 API](https://facebook.github.io/zstd/zstd_manual.html) 在内存解压，App 内置 Homebrew 提供的 `libzstd`。采用其 BSD 3-Clause 许可证，完整文本随包置于 `Contents/Resources/ThirdPartyNotices/Zstandard-LICENSE.txt`。项目使用本地运行时，不复制上游算法源代码。
