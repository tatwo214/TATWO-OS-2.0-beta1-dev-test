#!/bin/bash
set -u
for url in 'https://registry.npmjs.org/@openai/codex/latest' 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest'; do
  echo "GET $url (once)"
  curl -fsS --max-time 20 "$url" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{let p=JSON.parse(s);console.log(JSON.stringify({name:p.name,version:p.version}))}catch{console.log("查不到最新版本")}})'
done
r=$(mktemp -d /tmp/w298a-network.XXXXXX)
mkdir -p "$r/home" "$r/live"
echo 'grok --no-auto-update update --check (once)'
env HOME="$r/home" TATWO2_LIVE_ROOT="$r/live" GROK_HOME="$r/home/grok" '/Applications/TATWO OS.app/Contents/Resources/runtime/bin/grok' --no-auto-update update --check
