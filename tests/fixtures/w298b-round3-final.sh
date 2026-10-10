#!/bin/bash
set -euo pipefail
WT="$1"
T="$HOME/tatwo-build"
C="$T/tmp/W248-webspace/cef"
export TATWO_ENABLE_CEF=1
export TATWO_CEF_ROOT="$C/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal"
export TATWO_CEF_WRAPPER_LIBRARY="$C/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a"
export TATWO2_W248_CEF_RECEIPT="$T/tmp/W298b-round3/w248-cef.json"
export TATWO2_W258_CEF_RECEIPT="$T/tmp/W298b-round3/w258-cef.json"
export TATWO_BROWSER_TABS_NATIVE=1
unset TATWO2_W258_REAL_SITE
# The authoritative list is read from the unchanged P027 snapshot.
LIST=$(grep -o 'tests/[^ ]*\.mjs' "$WT/tests/fixtures/w298b-round3-p027.sh" | sort -u)
bash "$WT/tests/fixtures/w298b-round3-verify-serial.sh" "$WT" w298b,w298a,w214,w288,w189commands $LIST tests/w298b-ai-install.test.mjs tests/w298a-ai-update.test.mjs
