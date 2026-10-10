#!/bin/bash
set -u
r=$(mktemp -d /tmp/w298a-research.XXXXXX)
mkdir -p "$r/home" "$r/live"
for cli in '/Applications/TATWO OS.app/Contents/Resources/codex-vendor/aarch64-apple-darwin/bin/codex' '/Applications/TATWO OS.app/Contents/Resources/claude-sidecar/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude' '/Applications/TATWO OS.app/Contents/Resources/runtime/bin/grok' "$HOME/.local/bin/codex" "$HOME/.local/bin/claude"; do
  echo "$cli"
  env HOME="$r/home" TATWO2_LIVE_ROOT="$r/live" CODEX_HOME="$r/home/codex" CLAUDE_CONFIG_DIR="$r/home/claude" GROK_HOME="$r/home/grok" DISABLE_AUTOUPDATER=1 "$cli" --version
  /usr/bin/codesign --verify --strict "$cli" 2>&1
  /usr/bin/codesign -dv "$cli" 2>&1 | sed -n '/TeamIdentifier=/p'
done
env HOME="$r/home" TATWO2_LIVE_ROOT="$r/live" GROK_HOME="$r/home/grok" '/Applications/TATWO OS.app/Contents/Resources/runtime/bin/grok' --no-auto-update models
