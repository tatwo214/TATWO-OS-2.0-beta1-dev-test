#!/bin/bash
set -eu
cd "$1"
export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
node --test tests/public-privacy.test.mjs
