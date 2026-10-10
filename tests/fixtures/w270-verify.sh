#!/bin/bash
set -eu
TATWO_VERIFY_ROOT="$HOME/tatwo-build"
export TATWO_ENABLE_CEF=1
export TATWO_CEF_ROOT=${TATWO_VERIFY_ROOT}/tmp/W248-webspace/cef/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal
export TATWO_CEF_WRAPPER_LIBRARY=${TATWO_VERIFY_ROOT}/tmp/W248-webspace/cef/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a
export TMPDIR=${TATWO_VERIFY_ROOT}/tmp/W270-dlfly/
export TATWO2_W248_CEF_RECEIPT="$TMPDIR/cef-app.json"
export TATWO_BROWSER_TABS_NATIVE=1
unset SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
mkdir -p "$TMPDIR"
exec "${TATWO_VERIFY_ROOT}/verify.sh" "$(cd "$(dirname "$0")/../.." && pwd)" "$@"
