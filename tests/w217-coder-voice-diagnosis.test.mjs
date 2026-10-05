import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

// Diagnosis, not a claim that Coder voice works. The fixture runs the production
// sidecar against a fake app-server and records exactly what it can forward.
test('W217 Coder baseline: voice operations are rejected before app-server; text provider survives config preparation',
  { timeout: 15000 }, async () => {
    const root = testScratch('w217-coder-');
    const home = path.join(root, 'home');
    const engine = path.join(root, 'engines/codex');
    const source = path.join(root, 'synthetic-source');
    const bin = path.join(root, 'bin');
    await Promise.all([home, engine, source, bin].map(p => fs.mkdir(p, { recursive: true })));
    const textConfig = 'model_provider = "model_gateway"\n\n[model_providers.model_gateway]\nbase_url = "http://127.0.0.1:9/v1"\nwire_api = "responses"\n';
    await fs.writeFile(path.join(engine, 'config.toml'), textConfig);
    await fs.writeFile(path.join(source, 'config.toml'), '[mcp_servers.synthetic]\ncommand = "synthetic-command"\n');
    const capture = path.join(root, 'requests.jsonl');
    await fs.writeFile(path.join(bin, 'codex'), `#!${process.execPath}
const fs = require('node:fs');
if (process.argv.includes('--version')) { console.log('codex-synthetic 1'); process.exit(0); }
const send = value => process.stdout.write(JSON.stringify(value)+'\\n');
const rl = require('node:readline').createInterface({ input: process.stdin });
rl.on('line', line => {
  const request = JSON.parse(line);
  fs.appendFileSync(process.env.W217_CAPTURE, line+'\\n');
  if (request.method === 'initialize') send({id:request.id,result:{}});
  if (request.method === 'thread/start') send({id:request.id,result:{thread:{id:'synthetic-thread'}}});
});
rl.on('close',()=>process.exit(0));
`, { mode: 0o700 });
    const child = spawn(process.execPath, [
      fileURLToPath(new URL('../Engines/codex-sidecar/sidecar.mjs', import.meta.url)),
      '--cwd', root, '--model', 'synthetic-gpt',
    ], {
      env: {
        PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
        HOME: home, CODEX_HOME: engine, TATWO2_CODEX_SOURCE_HOME: source,
        W217_CAPTURE: capture,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const events = [];
    let buffer = '', stderr = '', timer;
    child.stderr.on('data', chunk => { stderr += chunk; });
    const rejected = new Promise((resolve, reject) => {
      child.on('error', reject);
      child.stdout.on('data', chunk => {
        buffer += chunk;
        while (buffer.includes('\n')) {
          const at = buffer.indexOf('\n');
          events.push(JSON.parse(buffer.slice(0, at)));
          buffer = buffer.slice(at + 1);
        }
        if (events.filter(e => e.ev === 'error').length >= 2) resolve();
      });
      timer = setTimeout(() => reject(new Error(`synthetic sidecar timeout: ${stderr}`)), 10000);
    });
    try {
      child.stdin.write(JSON.stringify({ op: 'voice_start' }) + '\n');
      child.stdin.write(JSON.stringify({ op: 'voice_stop' }) + '\n');
      await rejected;
      assert.deepEqual(events.filter(e => e.ev === 'error').map(e => e.message),
        ['unknown op voice_start', 'unknown op voice_stop']);
      const exited = once(child, 'exit');
      child.stdin.end();
      assert.equal((await exited)[0], 0, stderr);
      const requests = (await fs.readFile(capture, 'utf8')).trim().split('\n').map(JSON.parse);
      assert.equal(requests.filter(r => /voice|realtime|audio/.test(r.method ?? '')).length, 0);
      const generated = await fs.readFile(path.join(engine, 'config.toml'), 'utf8');
      assert.ok(generated.startsWith(textConfig), 'config preparation preserves the textual provider and gateway');
      assert.match(generated, /\[mcp_servers\.synthetic\]/, 'the actual config preparer only imported the fake MCP section');
      assert.equal(await fs.readFile(path.join(source, 'config.toml'), 'utf8'),
        '[mcp_servers.synthetic]\ncommand = "synthetic-command"\n');
    } finally {
      clearTimeout(timer);
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    }
  });
