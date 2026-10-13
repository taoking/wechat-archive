#!/bin/zsh
set -euo pipefail
umask 077
project_root=${0:A:h:h}
exec python3 "$project_root/tools/wechat_keys/workflow.py" keys "$@"
