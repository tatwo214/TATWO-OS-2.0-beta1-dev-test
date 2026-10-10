#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
node --test tests/w294-plugins.test.mjs tests/w208-tap-stress.test.mjs tests/w185-tap-model.test.mjs tests/w185-tap-ui.test.mjs tests/w183-r12-connect-ui.test.mjs tests/public-privacy.test.mjs
