#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

if (( $# != 0 )); then
    print -u2 "Usage: $0"
    exit 2
fi

swift build -c release --product WeChatArchive
bin_path="$(swift build -c release --show-bin-path)"
dist_path="$project_root/dist"
app_path="$dist_path/微信聊天归档.app"
contents_path="$app_path/Contents"

if [[ -e "$app_path" ]]; then
    print -u2 "Refusing to overwrite existing artifact: $app_path"
    print -u2 "Move it aside or remove it explicitly, then run this script again."
    exit 1
fi

mkdir -p "$contents_path/MacOS"
cp "$script_dir/WeChatArchive-Info.plist" "$contents_path/Info.plist"
cp "$bin_path/WeChatArchive" "$contents_path/MacOS/WeChatArchive"
# This is an ad-hoc local build, not a Developer ID signed or notarized app.
codesign --force --deep --sign - "$app_path"
print "Created local release app: $app_path"
