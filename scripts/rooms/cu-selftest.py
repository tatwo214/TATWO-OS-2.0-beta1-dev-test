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
    ap.add_argument("--project", default=None, help="專案 UUID；不給就開在一般")
    args = ap.parse_args()
    message = open(args.message_file, encoding="utf-8").read()
    created = rpc("new_thread", dict({"title": args.title}, **({"projectID": args.project} if args.project else {})))
    tid = (created.get("result") or {}).get("threadID")
    if not tid:
        print("new_thread failed:", json.dumps(created, ensure_ascii=False)[:300]); return 2
    print("thread:", tid)
    print("select:", json.dumps(rpc("select_thread", {"threadID": tid}), ensure_ascii=False)[:120])
    time.sleep(2)
    # 2026-09-21：App 剛重啟時，new_thread 可能早於磁碟文件載入完成，剛建的討論串被蓋掉，send 回 invalid_params，
    # 腳本就空等到逾時。送出失敗先等再試；最後一次重建討論串。送不出去就明確結束，不要空轉。
    sent = None
    for attempt in range(4):
        sent = rpc("send_message", {"threadID": tid, "text": message})
        print("send:", json.dumps(sent, ensure_ascii=False)[:120], flush=True)
        if sent.get("ok"): break
        time.sleep(6)
        if attempt == 2:
            created = rpc("new_thread", dict({"title": args.title}, **({"projectID": args.project} if args.project else {})))
            tid = (created.get("result") or {}).get("threadID") or tid
            print("re-created thread:", tid, flush=True); rpc("select_thread", {"threadID": tid}); time.sleep(2)
    if not (sent or {}).get("ok"):
        # App 會把拒收原因寫成討論串裡的系統訊息（最常見：使用者在設定 › 模型登入「禁用 API」）。
        # 印出來，不要只丟 invalid_params 讓人瞎猜。
        reason = ""
        try:
            for m in (rpc("transcript", {"threadID": tid}, timeout=20).get("result") or {}).get("messages") or []:
                if m.get("role") == "system" and m.get("text"): reason = m["text"]
        except OSError: pass
        print("=== REPORT ===\n(訊息送不進 App：" + json.dumps(sent, ensure_ascii=False)[:120] + ("；App 說：" + reason if reason else "") + ")")
        return 2
    seen, deadline, msgs, silent, quiet = 0, time.time() + args.timeout, [], 0, 0
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
        # 代理中途也會說一段 done 的長話（例如「等 25 秒再截圖」）；要連續兩次輪詢都沒有新訊息才算真的收工。
        if last.get("role") == "assistant" and last.get("status") == "done" and len(last.get("text") or "") > 120:
            quiet += 1
            if quiet >= 2: break
        else:
            quiet = 0
    print("=== REPORT ===")
    print((msgs[-1].get("text") or "") if msgs else "(no messages)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
