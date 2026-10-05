// Playback behavior is exercised by native w209spotify and Rust recovery tests.
// These tests execute the existing bundler against a fake cargo/codesign in isolated directories.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const bundler = path.join(root, 'scripts/bundle-spotify.py');
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'w209-bundle-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const source = path.join(dir, 'source'), rust = path.join(dir, 'rust');
  fs.mkdirSync(path.join(source, 'src'), { recursive: true });
  for (const name of ['Cargo.toml', 'Cargo.lock', 'LICENSE-librespot']) {
    fs.copyFileSync(path.join(root, 'Engines/spotify-helper', name), path.join(source, name));
  }
  fs.writeFileSync(path.join(source, 'src/main.rs'), '// fixture source\n');
  fs.mkdirSync(path.join(rust, 'cargo/bin'), { recursive: true });
  fs.writeFileSync(path.join(rust, 'cargo/bin/cargo'), `#!/usr/bin/env python3
import os,sys,json,pathlib
with open(os.environ['CALLS'],'a') as f: f.write(json.dumps({'args':sys.argv[1:], 'cargo':os.environ['CARGO_HOME'], 'rustup':os.environ['RUSTUP_HOME']})+'\\n')
target=pathlib.Path(sys.argv[sys.argv.index('--target-dir')+1])/'release/tatwo-spotify'
target.parent.mkdir(parents=True,exist_ok=True)
target.write_bytes(b'fake-helper-not-for-execution')
`, { mode: 0o700 });
  const app = path.join(dir, 'app'), cache = path.join(dir, 'cache');
  const calls = path.join(dir, 'calls.jsonl');
  function run(code, extraEnv = {}) {
    return spawnSync('python3', ['-c', `import importlib.util, pathlib, os, json
spec=importlib.util.spec_from_file_location('bundle',${JSON.stringify(bundler)})
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.SOURCE=pathlib.Path(${JSON.stringify(source)})
app=pathlib.Path(${JSON.stringify(app)});cache=pathlib.Path(${JSON.stringify(cache)})
${code}`], { encoding: 'utf8', env: { ...process.env, TATWO2_RUST_HOME: rust, CALLS: calls, ...extraEnv } });
  }
  return { dir, source, rust, app, cache, run,
    calls: () => fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse) : [],
    manifest: () => JSON.parse(fs.readFileSync(path.join(app, 'Contents/Resources/spotify-helper/manifest.json'), 'utf8')) };
}
function success(result) { assert.equal(result.status, 0, result.stderr); }

test('prepare executes locked cargo with the selected Rust home and copies helper/license/manifest', (t) => {
  const f = fixture(t);
  success(f.run('m.prepare(app,cache)'));
  const calls = f.calls();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args.slice(0, 4), ['build', '--release', '--locked', '--target-dir']);
  assert.equal(calls[0].cargo, path.join(f.rust, 'cargo'));
  assert.equal(calls[0].rustup, path.join(f.rust, 'rustup'));
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Helpers/tatwo-spotify'), 'utf8'), 'fake-helper-not-for-execution');
  assert.ok(fs.statSync(path.join(f.app, 'Contents/Helpers/tatwo-spotify')).mode & 0o100);
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/spotify-helper/LICENSE-librespot'), 'utf8'),
    fs.readFileSync(path.join(f.source, 'LICENSE-librespot'), 'utf8'));
  assert.equal(f.manifest().librespot, '0.8.0');
  assert.equal(f.manifest().signedSHA256, null);
});

test('unchanged source reuses the cache; changed source builds a new digest', (t) => {
  const f = fixture(t);
  success(f.run('m.prepare(app,cache)'));
  const before = f.manifest().sourceSHA256;
  success(f.run('m.prepare(app,cache)'));
  assert.equal(f.calls().length, 1);
  fs.appendFileSync(path.join(f.source, 'src/main.rs'), '// change\n');
  success(f.run('m.prepare(app,cache)'));
  assert.equal(f.calls().length, 2);
  assert.notEqual(f.manifest().sourceSHA256, before);
});

test('missing cargo fails closed unless the explicit development skip is set', (t) => {
  const f = fixture(t);
  const unavailable = 'm.cargo_command=lambda:(None,dict(os.environ))\nm.prepare(app,cache)';
  const failure = f.run(unavailable, { TATWO2_SKIP_SPOTIFY_HELPER: '' });
  assert.notEqual(failure.status, 0);
  success(f.run(unavailable, { TATWO2_SKIP_SPOTIFY_HELPER: '1' }));
  assert.equal(fs.existsSync(path.join(f.app, 'Contents/Helpers/tatwo-spotify')), false);
});

test('finalize signs and verifies the prepared helper, but rejects pre-sign tampering', (t) => {
  const f = fixture(t);
  success(f.run('m.prepare(app,cache)'));
  const bin = path.join(f.dir, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'codesign'), `#!/usr/bin/env python3
import sys,pathlib,json,os
with open(os.environ['SIGN_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if '--sign' in sys.argv:
    p=pathlib.Path(sys.argv[-1]);p.write_bytes(p.read_bytes()+b'-signed')
`, { mode: 0o700 });
  const signCalls = path.join(f.dir, 'sign.jsonl');
  const env = { PATH: bin + path.delimiter + process.env.PATH, SIGN_CALLS: signCalls };
  success(f.run("m.finalize(app,'fixture-identity')", env));
  const calls = fs.readFileSync(signCalls, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(calls[0].slice(0, 5), ['--force', '--sign', 'fixture-identity', '--timestamp=none', path.join(f.app, 'Contents/Helpers/tatwo-spotify')]);
  assert.equal(calls[1][0], '--verify');
  assert.notEqual(f.manifest().unsignedSHA256, f.manifest().signedSHA256);
  fs.appendFileSync(path.join(f.app, 'Contents/Helpers/tatwo-spotify'), 'tamper');
  assert.notEqual(f.run("m.finalize(app,'fixture-identity')", env).status, 0);
  assert.equal(fs.readFileSync(signCalls, 'utf8').trim().split('\n').length, 2);
});
