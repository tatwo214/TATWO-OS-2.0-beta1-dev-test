#!/bin/bash
# W94：自建 CEF 時對 Chromium 原始碼套的本機修補（冪等；每次 automate-git 前跑）。
# 只放「新 SDK 相容」這類不改行為的修補；每條註明來源與原因。
set -euo pipefail
SRC="${1:?usage: cef-local-patches.sh <chromium/src>}"
[ -d "$SRC/sandbox/mac" ] || { echo "no chromium src at $SRC; skip"; exit 0; }
# 1. macOS 27 SDK 拿掉 kSBXProfilePureComputation 的宣告（sandbox.h 只剩註解）。
#    值依 sandbox_init(3) 文件為 "pure-computation"，改用字面值；行為不變。
f="$SRC/sandbox/mac/seatbelt.cc"
if grep -q "kProfilePureComputation = kSBXProfilePureComputation;" "$f"; then
  sed -i "" 's|const char\* Seatbelt::kProfilePureComputation = kSBXProfilePureComputation;|const char* Seatbelt::kProfilePureComputation = "pure-computation";  // TATWO W94: macOS 27 SDK dropped kSBXProfilePureComputation|' "$f"
  echo "patched: sandbox/mac/seatbelt.cc (kSBXProfilePureComputation → literal)"
else
  echo "already patched: sandbox/mac/seatbelt.cc"
fi
# 2. CEF 154 把 component_updater::RegisterPathProvider 搬進 #if !BUILDFLAG(ENABLE_CEF)，CEF 不執行，
#    DIR_COMPONENT_USER 沒登記 → 所有元件（含 Widevine）裝不起來 → Spotify 網頁播放器啟動失敗、按鈕沒反應。
#    在 CEF 分支補登記同一個路徑提供者（Chrome 本來就這樣做）；不改其他行為。10-06 實機查證。
f="$SRC/chrome/app/chrome_main_delegate.cc"
python3 - "$f" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
marker = "TATWO local patch: component path provider"
if marker in s:
    print("already patched: chrome/app/chrome_main_delegate.cc")
else:
    anchor = "#endif  // !defined(BUILDING_CHROME_RENDERER)\n#endif  // !BUILDFLAG(ENABLE_CEF)\n"
    assert s.count(anchor) == 1, "anchor count %d" % s.count(anchor)
    add = ("#if BUILDFLAG(ENABLE_CEF)\n"
           "  // " + marker + ": CEF 154 moved this call into the !ENABLE_CEF block above,\n"
           "  // leaving DIR_COMPONENT_USER unregistered so no component (Widevine) can install.\n"
           "  component_updater::RegisterPathProvider(chrome::DIR_COMPONENTS,\n"
           "                                          chrome::DIR_USER_DATA);\n"
           "#endif  // BUILDFLAG(ENABLE_CEF)\n")
    open(p, "w").write(s.replace(anchor, anchor + add)); print("patched: chrome/app/chrome_main_delegate.cc (component path provider)")
PY
