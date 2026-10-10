T=~/tatwo-build; O=$T/tmp/P027-verify2.out; WT=$T/rooms/P027-preview; cd $WT || exit 2
F="BUILD FAILED|error:|exit=|^ℹ (tests|pass|fail|skipped)|SUMMARY|^✖|SKIP"
{ echo "head=$(git rev-parse HEAD)"; export PATH=$HOME/.local/bin:$PATH
  echo "== PASS A (no CEF)"
  mkdir -p $T/tmp/P027a2; TMPDIR=$T/tmp/P027a2/ bash $T/verify.sh $WT w214,w216,w188display,w211,w288,w292,w189commands,w208tap,w185tap,w183connect,w295,w297 tests/w178-security.test.mjs tests/w212-keytap.test.mjs tests/w224-fixes.test.mjs tests/w227-keylog.test.mjs tests/public-privacy.test.mjs tests/browser-workspace-design.test.mjs tests/w177-chatgpt-space.test.mjs tests/w276-staging.test.mjs tests/w277-telemetry-cap.test.mjs tests/w278-media-cost.test.mjs tests/w283-plan-export.test.mjs tests/w284-workpath.test.mjs tests/claude-sidecar-steering.test.mjs tests/claude-sidecar-attachments.test.mjs tests/claude-sidecar-readonly.test.mjs tests/codex-sidecar-cancellation.test.mjs tests/w288-coderfix.test.mjs tests/w289-xdiag.test.mjs tests/w292-connectcard.test.mjs tests/w286-steering-app-acceptance.mjs tests/w294-plugins.test.mjs tests/w208-tap-stress.test.mjs tests/w185-tap-model.test.mjs tests/w293-mockkeychain.test.mjs tests/w293b-keychain.test.mjs  > $T/tmp/P027a2-full.log 2>&1
  grep -E "$F" $T/tmp/P027a2-full.log | sort | uniq -c | sort -rn | head -20
  echo "== PASS B (CEF)"
  C=$T/tmp/W248-webspace/cef
  export TATWO_ENABLE_CEF=1 TATWO_CEF_ROOT=$C/vendor/cef/runtime/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal
  export TATWO_CEF_WRAPPER_LIBRARY=$C/build-cef/fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230/d00d945d618af1a8135791d951a27eb19eaf362b556b10331b74d875da7b07d6/libcef_dll_wrapper.a
  B=$T/tmp/P027b2; mkdir -p $B; export TATWO2_W248_CEF_RECEIPT=$B/w248.json TATWO2_W258_CEF_RECEIPT=$B/w258.json
  TMPDIR=$B/ TATWO_BROWSER_TABS_NATIVE=1 bash $T/verify.sh $WT w258download,w248webspace,w265dmchatgpt,w269gptchrome,w294e tests/w248-webspace.test.mjs tests/w265-dmchatgpt.test.mjs tests/browser-download-permissions-repair.test.mjs tests/browser-web-features.test.mjs tests/w291-translate.test.mjs tests/w295-xsmooth.test.mjs > $T/tmp/P027b2-full.log 2>&1
  grep -E "$F" $T/tmp/P027b2-full.log | sort | uniq -c | sort -rn | head -24
  D=$(ls -td $T/verify/P027-preview-* | head -1); grep -h -E "W2(58|68|70|81|81b|81f|82) SUMMARY" $D/selftest-w258download.log 2>/dev/null | head
} > $O 2>&1; echo P027_DONE >> $O
