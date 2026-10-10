#!/bin/bash
# Studio：在指定工作副本建置＋node 測試＋App 自測（隔離環境）。主導與施工房都用這支，不要直接 swift build。
# 用法：verify.sh <工作副本絕對路徑> <自測名[,自測名…]|-> [node 測試...]
# 環境：Metal 工具組（從 mini 搬來，PATH）＋ macOS 27 SDK 的框架巨集外掛（-plugin-path）；命令列工具版 Swift。一次一個建置（mkdir 鎖，只罩建置）。
set -uo pipefail
WT="$1"; STS="$2"; shift 2
T="$HOME/tatwo-build"; name="$(basename "$WT")"; out="$T/verify/$name-$(date +%H%M%S)"; mkdir -p "$out"
export PATH="$T/toolchains.noindex/Metal27.xctoolchain/usr/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PLUG="$T/toolchains.noindex/macosx-plugins"
lock="$T/build.lock"; waited=0
until mkdir "$lock" 2>/dev/null; do sleep 5; waited=$((waited+5)); [ $waited -gt 3600 ] && { echo "build lock wait > 1h"; exit 2; }; done
trap 'rmdir "$lock" 2>/dev/null' EXIT
{
echo "BUILD $name @ $(git -C "$WT" rev-parse --short HEAD) (lock wait ${waited}s)"
echo "free+inactive $(vm_stat | awk '/Pages free|Pages inactive/ {gsub("\\.","",$NF); s+=$NF} END {printf "%.1fGB", s*16384/1073741824}')"
start=$(date +%s)
( cd "$WT" && swift build -Xswiftc -plugin-path -Xswiftc "$PLUG" ) > "$out/build.log" 2>&1; rc=$?
echo "swift build exit=$rc seconds=$(( $(date +%s)-start ))"
# 鎖只罩建置；測試用各自工作副本的執行檔與隔離家目錄，可以多房並行（10-03 主導）。
rmdir "$lock" 2>/dev/null; trap - EXIT
if [ $rc -ne 0 ]; then sed -e 's/\x1b\[[0-9;]*m//g' "$out/build.log" | grep -E '\.swift:[0-9]+:[0-9]+: error|^error:' | head -30; echo "BUILD FAILED — skip tests"; exit 0; fi
BIN="$WT/.build/debug/Tatwo2"
if [ $# -gt 0 ]; then
  echo "== node $*"
  ( cd "$WT" && TATWO2_TEST_BINARY="$BIN" node --test --test-concurrency=1 "$@" ) > "$out/node.log" 2>&1
  grep -E '^(ℹ (tests|pass|fail|skipped)|✖)' "$out/node.log"
fi
for ST in ${STS//,/ }; do
  [ "$ST" = "-" ] && continue
  r="$T/tmp/lv/$$-$ST"; rm -rf "$r"; mkdir -p "$r"/{home,live,engines/codex,engines/claude,os,docs} "$out/artifacts/$ST"
  echo "== selftest $ST"
  env HOME="$r/home" CFFIXED_USER_HOME="$r/home" TATWO_STAGING_SCRATCH_HOME="$r/home" TATWO_STAGING_ROOT="$r" \
    TATWO2_LIVE_ROOT="$r/live" TATWO2_ENGINES_ROOT="$r/engines" CODEX_HOME="$r/engines/codex" TATWO2_CODEX_SOURCE_HOME="$r/engines/codex" \
    CLAUDE_CONFIG_DIR="$r/engines/claude" CLAUDE_SECURESTORAGE_CONFIG_DIR="$r/engines/claude" \
    TATWO2_OS_SOCKET="$r/o.sock" TATWO2_BROWSER_SOCKET="$r/b.sock" TATWO2_OS_ROOT="$r/os" TATWO2_DOCS_ROOT="$r/docs" \
    TATWO2_OS_UPSTREAM_PATH="$r/os/os-upstream.md" TATWO2_SKILLET_PATH="$r/os/skillet.md" TATWO2_SELFTEST="$ST" TATWO2_SELFTEST_ARTIFACTS="$out/artifacts/$ST" \
    "$BIN" > "$out/selftest-$ST.log" 2>&1 &
  pid=$!; t=0; limit="${SELFTEST_LIMIT:-1200}"
  while kill -0 $pid 2>/dev/null; do sleep 2; t=$((t+2)); if [ $t -ge $limit ]; then kill $pid 2>/dev/null; sleep 2; kill -9 $pid 2>/dev/null; echo "SELFTEST TIMEOUT ${limit}s（自測名稱不存在時程式會當一般 App 啟動）"; break; fi; done
  wait $pid 2>/dev/null; src=$?
  grep -cE " PASS" "$out/selftest-$ST.log" | sed 's/^/PASS lines: /'; grep -E "FAIL|SUMMARY|ALL PASS|blocked" "$out/selftest-$ST.log" | tail -8; echo "selftest $ST exit=$src"
  rm -rf "$r"
done
} > "$out/verify.log" 2>&1
cat "$out/verify.log"
echo "DONE $out"
