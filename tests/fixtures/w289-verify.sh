#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
build_root="$HOME/tatwo-build"
export TATWO_ENABLE_CEF=1
export TATWO_CEF_ROOT="$build_root/tmp/W248-webspace/cef/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal"
export TATWO_CEF_WRAPPER_LIBRARY="$build_root/tmp/W248-webspace/cef/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a"
export TMPDIR="$build_root/tmp/W289-xdiag/"
export TATWO2_W248_CEF_RECEIPT="$TMPDIR/w248-app.json"
export TATWO_BROWSER_TABS_NATIVE=1
mkdir -p "$TMPDIR"
unset SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
if [ "${1:-}" = native ]; then
  exec python3 "$repo/tests/fixtures/w289-run.py" "${2:-$TMPDIR/native}"
fi
if [ "${1:-}" = build ]; then
  exec "$build_root/verify.sh" "$repo" - tests/w289-xdiag.test.mjs tests/w278-media-cost.test.mjs tests/w257-xsmooth.test.mjs
fi
"$build_root/verify.sh" "$repo" w258download,w248webspace tests/w289-xdiag.test.mjs tests/w278-media-cost.test.mjs tests/w257-xsmooth.test.mjs tests/public-privacy.test.mjs tests/w248-webspace.test.mjs tests/browser-download-permissions-repair.test.mjs tests/browser-memory-policy.test.mjs tests/w184-tent.test.mjs tests/w85-media-fallback.test.mjs
