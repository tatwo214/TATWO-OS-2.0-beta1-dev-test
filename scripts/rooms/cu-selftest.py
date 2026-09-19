#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 OS 內建 Computer Use 讓 TATWO OS 自測（/goal 101 G3）。
用法：cu-selftest.py --title <討論串標題> --message-file <檢查清單.md> [--timeout 秒]
流程：os.sock new_thread → select_thread（Computer Use 只接受目前選取的本機聊天）→ send_message → 輪詢 transcript，
印出代理的最後一則回報。前提：聊天權限預設是「全權」（W102：才允許以 TATWO OS 自己為目標），
且 TATWO OS 有「輔助使用」「螢幕錄製」系統權限。跑的時候不要動 App（切討論串會讓 Computer Use 撤回）。"""
import argparse, json, os, socket, sys, time

SOCK = os.path.expanduser("~/Library/Application Support/tatwo2/live/os.sock")

def rpc(method, params=None, timeout=180):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(SOCK)
    s.sendall(json.dumps({"id": "cu", "method": method, "params": params or {}}).encode())
    s.shutdown(socket.SHUT_WR)   # server 是 readToEnd()，一定要半關閉
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
    return json.loads(buf.decode())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--message-file", required=True)
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    message = open(args.message_file, encoding="utf-8").read()
    created = rpc("new_thread", {"title": args.title})
    tid = (created.get("result") or {}).get("threadID")
    if not tid:
        print("new_thread failed:", json.dumps(created, ensure_ascii=False)[:300]); return 2
    print("thread:", tid)
    print("select:", json.dumps(rpc("select_thread", {"threadID": tid}), ensure_ascii=False)[:120])
    time.sleep(2)
    print("send:", json.dumps(rpc("send_message", {"threadID": tid, "text": message}), ensure_ascii=False)[:120])
    seen, deadline, msgs, silent = 0, time.time() + args.timeout, [], 0
    while time.time() < deadline:
        time.sleep(15)
        try:
            msgs = (rpc("transcript", {"threadID": tid}, timeout=20).get("result") or {}).get("messages") or []
        except OSError as error:
            # App 主執行緒卡住時 RPC 不會回；這本身就是要回報的結果，不要讓腳本直接崩掉。
            print(f"[transcript 沒回應：{error}；App 可能卡住，用 sample 看主執行緒]", flush=True)
            silent += 1
            if silent >= 4:
                print("=== REPORT ===\n(App 連續沒回應，自測中止；先 sample 主執行緒)"); return 2
            time.sleep(15); continue
        silent = 0
        if len(msgs) != seen:
            # 每則新的助理文字都完整印出：App 中途卡死或被砍時，已完成步驟的證據還在。
            for item in msgs[seen:]:
                text = item.get("text") or ""
                if item.get("role") == "assistant" and len(text) > 40 and not text.startswith("mcp__"):
                    print("--- assistant ---\n" + text, flush=True)
            seen = len(msgs); last = msgs[-1]
            print("n=%d %s %s %r" % (seen, last.get("role"), last.get("status"), (last.get("text") or "")[:120]), flush=True)
        last = msgs[-1] if msgs else {}
        if last.get("role") == "assistant" and last.get("status") == "done" and len(last.get("text") or "") > 120:
            break
    print("=== REPORT ===")
    print((msgs[-1].get("text") or "") if msgs else "(no messages)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
