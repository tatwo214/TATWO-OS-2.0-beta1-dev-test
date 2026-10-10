#!/bin/bash
set -uo pipefail
cd "$1" || exit 2
export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TATWO2_TEST_BINARY="$PWD/.build/debug/Tatwo2"
node --test --test-concurrency=1 tests/w178-security.test.mjs tests/w212-keytap.test.mjs tests/w224-fixes.test.mjs tests/w227-keylog.test.mjs tests/public-privacy.test.mjs tests/browser-workspace-design.test.mjs tests/w177-chatgpt-space.test.mjs tests/w222-project-lifecycle.test.mjs tests/w222c-entry.test.mjs tests/w222c-lifecycle.test.mjs tests/w222c-rename.test.mjs tests/w222c-retry.test.mjs tests/w222c-shared-folder.test.mjs tests/w183-one-press.test.mjs tests/w292-connectcard.test.mjs tests/w301-relaunch.test.mjs tests/w297-web-models.test.mjs tests/w276-staging.test.mjs tests/w277-telemetry-cap.test.mjs tests/w278-media-cost.test.mjs tests/w283-plan-export.test.mjs tests/w284-workpath.test.mjs tests/claude-sidecar-steering.test.mjs tests/claude-sidecar-attachments.test.mjs tests/claude-sidecar-readonly.test.mjs tests/codex-sidecar-cancellation.test.mjs tests/w288-coderfix.test.mjs tests/w289-xdiag.test.mjs tests/w292-connectcard.test.mjs tests/w286-steering-app-acceptance.mjs tests/w294-plugins.test.mjs tests/w208-tap-stress.test.mjs tests/w185-tap-model.test.mjs tests/w293-mockkeychain.test.mjs tests/w293b-keychain.test.mjs > "$2" 2>&1
result=$?
grep -E '^(ℹ (tests|pass|fail|skipped)|✖)' "$2"
exit "$result"
