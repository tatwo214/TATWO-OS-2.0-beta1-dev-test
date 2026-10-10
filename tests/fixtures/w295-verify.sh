#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
build_root="${TATWO_VERIFY_ROOT:-$HOME/tatwo-build}"
export TATWO_ENABLE_CEF=1
export TATWO_CEF_ROOT="$build_root/tmp/W248-webspace/cef/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal"
export TATWO_CEF_WRAPPER_LIBRARY="$build_root/tmp/W248-webspace/cef/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a"
export PATH="$build_root/toolchains.noindex/Metal27.xctoolchain/usr/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="$build_root/tmp/W295-xsmooth/"
mkdir -p "$TMPDIR"
export TATWO2_W248_CEF_RECEIPT="$TMPDIR/cef-app.json"
export TATWO_BROWSER_TABS_NATIVE=1
unset SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
if [ "${1:-}" = build ]; then
  until mkdir "$build_root/build.lock" 2>/dev/null; do sleep 5; done
  trap 'rmdir "$build_root/build.lock"' EXIT
  cd "$repo"
  # Build uses cached dependencies. Sandbox makes the no-network requirement executable.
  exec_build=(/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' /usr/bin/swift build --disable-sandbox --skip-update --disable-automatic-resolution -j 4 -Xswiftc -plugin-path -Xswiftc "$build_root/toolchains.noindex/macosx-plugins")
  "${exec_build[@]}"
else
  export TATWO2_TEST_BINARY="$repo/.build/debug/Tatwo2"
  cd "$repo"
  node --test tests/w248-webspace.test.mjs
  node --test tests/w295-xsmooth.test.mjs tests/w288-coderfix.test.mjs tests/public-privacy.test.mjs
fi
