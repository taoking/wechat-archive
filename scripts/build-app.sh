#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

if (( $# > 1 )); then
    print -u2 "Usage: $0 [output-directory]"
    exit 2
fi

swift build -c release --product WeChatArchive
bin_path="$(swift build -c release --show-bin-path)"
dist_path="${1:-$project_root/dist}"
if [[ "$dist_path" != /* ]]; then
    dist_path="$project_root/$dist_path"
fi
app_path="$dist_path/WeChat Archive.app"
contents_path="$app_path/Contents"
frameworks_path="$contents_path/Frameworks"
notices_path="$contents_path/Resources/ThirdPartyNotices"

sqlcipher_prefix="$(brew --prefix sqlcipher)"
openssl_prefix="$(brew --prefix openssl@4)"
sqlcipher_library="$sqlcipher_prefix/lib/libsqlcipher.dylib"
crypto_library="$openssl_prefix/lib/libcrypto.4.dylib"

if [[ ! -f "$sqlcipher_library" || ! -f "$crypto_library" ]]; then
    print -u2 "SQLCipher release runtime is unavailable. Run: brew bundle"
    exit 1
fi

if [[ -e "$app_path" ]]; then
    print -u2 "Refusing to overwrite existing artifact: $app_path"
    print -u2 "Move it aside or remove it explicitly, then run this script again."
    exit 1
fi

mkdir -p "$contents_path/MacOS" "$frameworks_path" "$notices_path"
cp "$script_dir/WeChatArchive-Info.plist" "$contents_path/Info.plist"
cp "$bin_path/WeChatArchive" "$contents_path/MacOS/WeChatArchive"
cp "$sqlcipher_library" "$frameworks_path/libsqlcipher.dylib"
cp "$crypto_library" "$frameworks_path/libcrypto.4.dylib"
cp "$sqlcipher_prefix/LICENSE.txt" "$notices_path/SQLCipher-LICENSE.txt"
cp "$openssl_prefix/LICENSE.txt" "$notices_path/OpenSSL-LICENSE.txt"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$notices_path/WeChatArchive-THIRD_PARTY_NOTICES.md"

# SQLCipher is loaded explicitly from Contents/Frameworks. Keep its OpenSSL
# dependency next to it so the shipped App never points at a Homebrew prefix.
install_name_tool -id "@rpath/libcrypto.4.dylib" "$frameworks_path/libcrypto.4.dylib"
install_name_tool -id "@rpath/libsqlcipher.dylib" "$frameworks_path/libsqlcipher.dylib"
install_name_tool -change "$crypto_library" "@loader_path/libcrypto.4.dylib" "$frameworks_path/libsqlcipher.dylib"

# This is an ad-hoc local build, not a Developer ID signed or notarized app.
codesign --force --sign - "$frameworks_path/libcrypto.4.dylib"
codesign --force --sign - "$frameworks_path/libsqlcipher.dylib"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
print "Created local release app: $app_path"
