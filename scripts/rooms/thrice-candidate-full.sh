#!/bin/bash
# Run from the primary's GUI Terminal session: signing and native-window tests
# need that session. Never change Keychain/TCC settings to make a test pass.
set -euo pipefail
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; S="${TATWO_STAGING:-$E/staging}"
C="${1:-$S/rooms/candidate-thrice}"
OUT="${2:-$S/tmp/full-thrice-$(date +%Y%m%d-%H%M%S)}"
W="${TATWO_THRICE_FIXTURES:-$S/tmp/w80}"
export PATH="${TATWO_BUILD_PATH:-$HOME/.tatwo-build-deps/tmux/3.6b/bin:/opt/homebrew/bin}:$PATH"
export TMPDIR="${TATWO_TEST_TMPDIR:-$S/tmp/thrice-candidate/}"
export W80B_GBRAIN_HELPER="${W80B_GBRAIN_HELPER:-$W/gbrain-probe-adhoc}"
export W80B_RELEASE_JSON="${W80B_RELEASE_JSON:-$W/evidence/release.json}"
export W80B_ASSET="${W80B_ASSET:-$W/gbrain-darwin-arm64}"
export W80B_LICENSE="${W80B_LICENSE:-$W/upstream/garrytan-gbrain-668b9ba/LICENSE}"

# Missing prerequisites are failures, not silent opt-out / stale-binary passes.
for tool in swift node rg python3; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }; done
for file in "$W80B_GBRAIN_HELPER" "$W80B_RELEASE_JSON" "$W80B_ASSET" "$W80B_LICENSE" "${TATWO_CEF_ROOT:-}/include/cef_app.h"; do
  [ -f "$file" ] || { echo "Missing full-suite fixture: $file" >&2; exit 2; }
done
[ -x "$W80B_GBRAIN_HELPER" ] || { echo 'GBrain test helper is not executable' >&2; exit 2; }
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "Preserving existing evidence: $OUT" >&2; exit 2; }
mkdir -p "$TMPDIR" "$(dirname "$OUT")" "$S/rooms"
cd "$C"
git diff --quiet HEAD -- || { echo 'Candidate has tracked changes; freeze before full acceptance' >&2; exit 2; }
HEAD="$(git rev-parse HEAD)"
LOCK="$S/rooms/.build-lock"
mkdir "$LOCK" 2>/dev/null || { echo "Build lock occupied: $LOCK (not stopping its owner)" >&2; exit 2; }
printf '%s\n' "$$" > "$LOCK/pid"
printf '%s\n' 'candidate full' > "$LOCK/owner"
release_lock() {
  # Remove only this invocation's lock, never another job's or a stale lock.
  if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$LOCK/pid" "$LOCK/owner"
    rmdir "$LOCK"
  fi
}
trap release_lock EXIT
BUILD_LOG="$(mktemp "${TMPDIR%/}/candidate-build.XXXXXX")"
echo "SOURCE $HEAD; BUILD_LOG $BUILD_LOG"
if swift build --product Tatwo2 --jobs "${TATWO2_BUILD_JOBS:-4}" > "$BUILD_LOG" 2>&1; then
  echo 'build exit=0'
else
  rc=$?; echo "build exit=$rc; no tests run with a stale binary" >&2; exit "$rc"
fi
# SwiftPM's SwiftBuild and native backends use different output directories.
BIN_DIR="$(swift build --show-bin-path)"
export TATWO2_TEST_BINARY="$BIN_DIR/Tatwo2"
[ -x "$TATWO2_TEST_BINARY" ] || { echo "Built product missing: $TATWO2_TEST_BINARY" >&2; exit 2; }
[ "$(git rev-parse HEAD)" = "$HEAD" ] && git diff --quiet HEAD -- || { echo 'Source changed during build' >&2; exit 2; }
shasum -a 256 "$TATWO2_TEST_BINARY"
release_lock
trap - EXIT
export TATWO_BROWSER_ADDRESS_NATIVE=1 TATWO_BROWSER_TABS_NATIVE=1
export TATWO_W67_NATIVE=1 TATWO_CLI_UI_RENDER=1
if bash scripts/tatwo-test-thrice.sh "$OUT"; then
  echo 'EXIT=0'
else
  rc=$?; echo "EXIT=$rc"; exit "$rc"
fi
