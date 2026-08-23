# Third-Party Notices

## Bundled SQLCipher runtime

The macOS release App bundles the SQLCipher runtime required for local database
export. SQLCipher is distributed under the BSD 3-Clause License. The exact
license text for the bundled binary is included in the App at
`Contents/Resources/ThirdPartyNotices/SQLCipher-LICENSE.txt`.

The release App also bundles the corresponding OpenSSL `libcrypto` runtime,
licensed under Apache License 2.0. Its exact license text is included alongside
the SQLCipher notice in the App bundle.

## Optional Silk decoder

Voice conversion can use the separately installed `silk_v3_decoder` executable
from [kn007/silk-v3-decoder](https://github.com/kn007/silk-v3-decoder). That
project is MIT licensed. Its SDK-derived Silk source files carry the upstream
Skype BSD-style redistribution notice, including its patent disclaimer.

This repository does not include, compile, or redistribute that decoder's
source or binary. When an operator installs the optional decoder, they are
responsible for retaining the upstream notices and complying with its license.
