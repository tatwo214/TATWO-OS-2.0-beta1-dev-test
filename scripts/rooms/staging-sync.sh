#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && "$1" == /* && "$1" != /Applications* && "$1" != *:* ]] || { echo 'Usage: staging-sync.sh <absolute local target directory outside /Applications>' >&2; exit 2; }
SOURCE="$HOME/tatwo-build/staging-app"
TARGET="$1"
/usr/bin/python3 - "$SOURCE/staging-receipt.json" "$TARGET" <<'PY'
import json,os,sys
r=json.load(open(sys.argv[1]))
if r.get('adHoc') or r.get('signingIdentity') == '-' or r.get('signingMode') in ('adhoc','ad-hoc'):
    raise SystemExit('ad-hoc staging is for local verification only; sync refused')
if r.get('bundleID') != 'ai.tatwo.tatwo2.staging' or r.get('buildStatus') != 'ready':
    raise SystemExit('only a verified signed staging artifact may be synced')
p=os.path.realpath(sys.argv[2])
if p == '/' or p == '/Applications' or p.startswith('/Applications/'):
    raise SystemExit('unsafe target')
if os.path.exists(os.path.join(p,'TATWO OS.app')): raise SystemExit('formal App present in target')
if p == os.path.realpath(os.path.dirname(sys.argv[1])): raise SystemExit('source equals target')
for name in ('TATWO OS Staging.app','staging-receipt.json','.staging-sync-archive'):
    if os.path.islink(os.path.join(p,name)): raise SystemExit('target entry is a symlink')
PY
codesign -v --deep --strict "$SOURCE/TATWO OS Staging.app"
[[ "$(codesign -d --verbose=4 "$SOURCE/TATWO OS Staging.app" 2>&1)" != *'Signature=adhoc'* ]] || { echo 'ad-hoc signature; sync refused' >&2; exit 1; }
mkdir -p "$TARGET"
# Keep replaced files in a local archive; never synchronize runtime/login data.
ARCHIVE="$TARGET/.staging-sync-archive/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$TARGET/TATWO OS Staging.app"
rsync -a --checksum --delete --backup --backup-dir="$ARCHIVE/app" \
    "$SOURCE/TATWO OS Staging.app/" "$TARGET/TATWO OS Staging.app/"
rsync -a --backup --backup-dir="$ARCHIVE/receipt" "$SOURCE/staging-receipt.json" "$TARGET/"
codesign -v --deep --strict "$TARGET/TATWO OS Staging.app"
