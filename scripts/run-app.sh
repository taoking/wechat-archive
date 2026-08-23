#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

if (( $# != 0 )); then
    print -u2 "Usage: $0"
    exit 2
fi

swift build --product WeChatArchive
bin_path="$(swift build --show-bin-path)"
app_path="$bin_path/WeChatArchive.app"
contents_path="$app_path/Contents"

mkdir -p "$contents_path/MacOS"
cp "$script_dir/WeChatArchive-Info.plist" "$contents_path/Info.plist"
cp "$bin_path/WeChatArchive" "$contents_path/MacOS/WeChatArchive"
# Copying Info.plist after SwiftPM signs the executable invalidates the bundle
# signature. Re-sign the local development bundle so LaunchServices can spawn it.
codesign --force --deep --sign - "$app_path"

open -n "$app_path"
