#!/bin/bash
# 退出 TATWO OS：送 quit，若跳「結束 TATWO OS？」確認框則按「結束」（使用者 2026-09-17 授權），等到程序消失。
pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || { echo "not running"; exit 0; }
# W103：先走 os.sock 的無人值守退出（跳過結束確認）；舊版 App 沒有這個 RPC 就退回 AppleScript quit。
python3 - <<'PY' >/dev/null 2>&1
import socket,json,os
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(os.path.expanduser("~/Library/Application Support/tatwo2/live/os.sock"))
s.sendall(json.dumps({"id":"q","method":"app_terminate_for_update","params":{"reason":"update"}}).encode()); s.shutdown(socket.SHUT_WR); s.recv(4096)
PY
sleep 2
pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || { echo "quit OK (rpc)"; exit 0; }
osascript -e 'tell application "TATWO OS" to quit' >/dev/null 2>&1 &
sleep 3
for i in 1 2 3; do
  osascript >/dev/null 2>&1 <<'AS'
tell application "System Events"
  tell process "tatwo2"
    repeat with w in windows
      try
        repeat with s in sheets of w
          if exists (button "結束" of s) then click button "結束" of s
        end repeat
      end try
    end repeat
  end tell
end tell
AS
  sleep 2; pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || break
done
for i in $(seq 1 40); do pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || { echo "quit OK"; exit 0; }; sleep 1; done
echo "still running"; exit 2
