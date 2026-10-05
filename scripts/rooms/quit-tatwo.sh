#!/bin/bash
# 退出 TATWO OS：舊版先走 os.sock 的無人值守退出；新版（W178 起外部程式不能叫它結束）改按 App 選單的「結束…」，
# 跳出確認片就按「結束」。只用輔助使用點按，不送按鍵、不強制砍程序。
APP_BIN="/Applications/TATWO OS.app/Contents/MacOS/tatwo2"
running() { pgrep -f "$APP_BIN" >/dev/null; }
running || { echo "not running"; exit 0; }
python3 - <<'PY' >/dev/null 2>&1
import socket, json, os
s = socket.socket(socket.AF_UNIX); s.settimeout(5)
s.connect(os.path.expanduser("~/Library/Application Support/tatwo2/live/os.sock"))
s.sendall(json.dumps({"id": "q", "method": "app_terminate_for_update", "params": {"reason": "update"}}).encode() + b"\n")
s.shutdown(socket.SHUT_WR); s.recv(4096)
PY
sleep 2; running || { echo "quit OK (rpc)"; exit 0; }
osascript >/dev/null 2>&1 <<'AS'
tell application "System Events" to tell process "tatwo2"
  repeat with m in (menu items of menu 1 of menu bar item 2 of menu bar 1)
    set t to name of m
    if t is not missing value and t starts with "結束" then
      click m
      exit repeat
    end if
  end repeat
end tell
AS
for i in 1 2 3 4 5; do
  sleep 2; running || break
  osascript >/dev/null 2>&1 <<'AS'
tell application "System Events" to tell process "tatwo2"
  repeat with w in windows
    try
      repeat with s in sheets of w
        if exists (button "結束" of s) then click button "結束" of s
      end repeat
    end try
    -- 主視窗沒開（例如只開著浮動私訊框）時，確認框是獨立視窗，不是確認片。
    try
      if exists (button "結束" of w) then click button "結束" of w
    end try
  end repeat
end tell
AS
done
for i in $(seq 1 40); do running || { echo "quit OK (menu)"; exit 0; }; sleep 1; done
echo "still running"; exit 2
