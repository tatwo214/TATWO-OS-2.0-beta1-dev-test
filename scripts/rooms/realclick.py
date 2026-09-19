#!/usr/bin/env python3
"""真實滑鼠事件自測（ui_probe）。用法：realclick.py scan [y] | click <wx> <wy> | state"""
import sys, json, time, subprocess, re
src = open(__file__.replace("realclick.py", "cu-selftest.py")).read().split("def main")[0]
argv = sys.argv[:]; sys.argv = ["x"]; exec(src)
import os
J = os.path.expanduser('~/Library/Application Support/TATWO OS/Browser/chat-tabs.json')
def window():
    out = subprocess.run(["swift", "/tmp/claude-winlist.swift"], capture_output=True, text=True).stdout
    m = re.findall(r"TATWO OS 0 \{\s*Height = (\d+);\s*Width = (\d+);\s*X = (-?\d+);\s*Y = (-?\d+);", out)
    h, w, x, y = max((tuple(map(int, item)) for item in m), key=lambda t: t[0] * t[1]); return x, y, w, h  # 主視窗＝最大的那個（浮空工具子視窗也在清單裡）
def probe(action, x, y):
    r = rpc("ui_probe", {"action": action, "x": x, "y": y}, timeout=15); return r.get("result") or r
def state():
    docked = subprocess.run(["defaults", "read", "ai.tatwo.tatwo2", "tatwo.chat.dockedBrowserWidth"], capture_output=True, text=True).stdout.strip()
    try: tabs = len(json.load(open(J))["tabs"])
    except Exception: tabs = -1
    return {"docked": docked, "tabs": tabs}
WX, WY, W, H = window()
cmd = argv[1]
if cmd == "state": print(WX, WY, W, H, state())
elif cmd == "scan":
    wy = float(argv[2]) if len(argv) > 2 else 18
    last = None
    for wx in range(200, W, 8):
        c = (probe("hit", WX + wx, WY + wy).get("chain") or ["?"])[0].split(" canMove")[0]
        if c != last: print(wx, c); last = c
elif cmd == "scanx":
    a, b, step, wy = int(argv[2]), int(argv[3]), int(argv[4]), float(argv[5]); last = None
    for wx in range(a, b, step):
        c = (probe("hit", WX + wx, WY + wy).get("chain") or ["?"])[0].split(" canMove")[0]
        if c != last: print(wx, c); last = c
elif cmd == "click":
    b = state(); r = probe("click", WX + float(argv[2]), WY + float(argv[3])); time.sleep(1.5)
    print("hit:", (r.get("chain") or ["?"])[0].split(" canMove")[0]); print(b, "->", state())
