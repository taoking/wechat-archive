# 第三方声明

## 随 App 打包的 SQLCipher runtime

macOS Release App 内置了本地数据库导出所需的 SQLCipher runtime。SQLCipher 以 BSD 3-Clause License 发布。随包二进制的完整许可证文本位于 App 内：`Contents/Resources/ThirdPartyNotices/SQLCipher-LICENSE.txt`。

Release App 同时内置对应的 OpenSSL `libcrypto` runtime，采用 Apache License 2.0。完整许可证文本与 SQLCipher 声明一同放在 App bundle 内。

## 可选 Silk 解码器

语音转换可使用单独安装的 [kn007/silk-v3-decoder](https://github.com/kn007/silk-v3-decoder) 项目的 `silk_v3_decoder` 可执行文件。该项目采用 MIT 许可证；其 SDK 衍生的 Silk 源文件带有上游 Skype BSD 风格再分发声明，其中包含专利免责声明。

本仓库不包含、编译或再分发该解码器的源代码或二进制文件。操作者安装可选解码器后，应自行保留上游声明并遵守其许可证。
