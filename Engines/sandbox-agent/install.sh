#!/bin/sh
set -eu
[ "$(id -u)" != 0 ] || { echo '拒絕 root；請用一般使用者，不用 sudo。' >&2; exit 1; }
command -v python3 >/dev/null
command -v git >/dev/null
umask 077
target="$HOME/.tatwo-sandbox"
[ ! -L "$target" ] || { echo '拒絕符號連結資料目錄。' >&2; exit 1; }
[ ! -L "$target/sandbox-agent.py" ] || { echo '拒絕符號連結執行檔。' >&2; exit 1; }
mkdir -p "$target"
chmod 700 "$target"
[ ! -e "$target/sandbox-agent.py" ] || cp "$target/sandbox-agent.py" "$target/sandbox-agent.py.$(date +%s).backup"
cp "$(dirname "$0")/sandbox-agent.py" "$target/sandbox-agent.py"
chmod 700 "$target/sandbox-agent.py"
echo '已安裝；下一步請在主設備設定 › 設備 › 沙盒加一台，再執行 README 的配對指令。'
