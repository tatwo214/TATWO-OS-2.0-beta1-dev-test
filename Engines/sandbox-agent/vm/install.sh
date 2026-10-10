#!/bin/sh
set -eu
[ "$(id -un)" = work ] || exit 1
cd "$(dirname "$0")"
sh install.sh
python3 "$HOME/.tatwo-sandbox/sandbox-agent.py" pair --gateway "$1" --name "$2"
if [ "$(uname)" != Darwin ]; then
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/tatwo-sandbox.service" <<UNIT
[Service]
Restart=on-failure
RestartSec=60
RestartPreventExitStatus=3
ExecStart=/usr/bin/python3 %h/.tatwo-sandbox/sandbox-agent.py run --runner sh
[Install]
WantedBy=default.target
UNIT
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  systemctl --user daemon-reload
  systemctl --user enable --now tatwo-sandbox.service
fi
