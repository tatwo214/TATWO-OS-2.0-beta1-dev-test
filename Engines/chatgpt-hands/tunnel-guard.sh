#!/bin/sh
# W183 R2（T10、T11）：cloudflared 的看門程式。沙盒外、只用 /bin/sh 內建指令與 /bin/sleep，和 cloudflared 同一個行程群組。
# cloudflared 不讀 stdin，App 當掉或被強制結束時它不會自己收；所以由這支替它讀 App 給的 stdin：
#   - stdin 收到 EOF（App 結束或當掉）→ 整組收掉；
#   - cloudflared 自己停了 → 整組收掉（App 看到這支結束就知道通道斷了）；
#   - 收到 SIGTERM／SIGINT／SIGHUP（App 收掉整組）→ 整組收掉。
# 不論怎麼結束，都先刪掉 token 檔（App 當掉也一樣，T10「用完刪」）。這支手上沒有 token 本身，只有檔名。
# 用法（App 用 -c 帶全文，不讓 /bin/sh 去讀這個檔：這組放棄了責任行程，讀不到外接卷等受保護位置）：
#   /bin/sh -c "<本檔全文>" chatgpt-hands/tunnel-guard <token 檔> /usr/bin/sandbox-exec -p <cloudflared.sb> -D … <cloudflared> tunnel … run --token-file <token 檔>
#   直接 /bin/sh tunnel-guard.sh <token 檔> … 也一樣能跑。
token_file=$1
shift
[ -n "$token_file" ] && [ "$#" -gt 0 ] || exit 64

cleanup() {
  trap '' HUP INT TERM
  trap - EXIT
  rm -f -- "$token_file"
  kill -TERM 0 2>/dev/null
  /bin/sleep 1
  kill -KILL 0 2>/dev/null
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

# App 給的 stdin 只留在 3 號給看門的那一段；cloudflared 本身拿 /dev/null，也拿不到 3 號。
exec 3<&0 </dev/null
"$@" 3<&- &
child=$!
{ while read -r _ <&3; do :; done; kill -TERM "$$" 2>/dev/null; } &
exec 3<&-
wait "$child"
