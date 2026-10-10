#!/bin/bash
# Offline CEF acceptance: disposable bundles, injected fake Keychain, no installed App.
set -euo pipefail
repo="${TATWO2_W293B_VERIFY_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
build_root="$HOME/tatwo-build"
out="${1:?evidence directory required}"
mkdir -p "$out"
# Bash reads files lazily. Execute an immutable snapshot so edits cannot alter
# a running acceptance command or accidentally execute the App outside isolation.
if [[ ${TATWO2_W293B_FROZEN:-0} != 1 ]]; then
    snapshot=$(mktemp "$out/runner.XXXXXX")
    cp "$0" "$snapshot"; chmod 444 "$snapshot"
    exec env TATWO2_W293B_FROZEN=1 TATWO2_W293B_VERIFY_REPO="$repo" /bin/bash "$snapshot" "$@"
fi
export PATH="$build_root/toolchains.noindex/Metal27.xctoolchain/usr/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TATWO_ENABLE_CEF=1
export TATWO_CEF_ROOT="$build_root/tmp/W248-webspace/cef/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal"
export TATWO_CEF_WRAPPER_LIBRARY="$build_root/tmp/W248-webspace/cef/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a"
export TMPDIR="$build_root/tmp/W293b-keychain/"
mkdir -p "$TMPDIR"
source "$repo/tests/fixtures/w276-offline-verify-env.sh"
export -f swift
if [[ ${2:-all} != system ]]; then
export TATWO2_W258_CEF_RECEIPT="$out/download-app.json"
"$build_root/verify.sh" "$repo" - tests/fixtures/w258-stage.mjs | tee "$out/cef-build.log"
grep -q "^swift build exit=0" "$out/cef-build.log"
cd "$repo"
clang -dynamiclib -Wno-deprecated-declarations script/tatwo2-staging-keychain.c -framework Security -o "$out/test-keychain.dylib"
codesign --force --sign - "$out/test-keychain.dylib"
export TATWO2_W293_TEST_INTERPOSER="$out/test-keychain.dylib"
download_binary="$repo/.build/debug/Tatwo2"
python3 tests/fixtures/w293-download.py "$out/download" "$download_binary" | tee "$out/download-exit.log"
unset TATWO2_W293_TEST_INTERPOSER
fi
cd "$repo"
TATWO2_STAGING_DYLIB=1 "$build_root/verify.sh" "$repo" - | tee "$out/staging-build.log"
grep -q "^swift build exit=0" "$out/staging-build.log"
TATWO2_W293_STAGING_BINARY="$repo/.build/debug/Tatwo2" python3 tests/fixtures/w293-system.py "$out/system" | tee "$out/system-exit.log"
