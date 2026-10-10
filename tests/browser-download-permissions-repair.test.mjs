import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {testScratch} from './helpers/test-scratch.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
test('native reservation cleanup preserves partial files, replacements and symlinks', () => {
  const dir = path.join(root, '.build/download-permissions-repair');
  fs.mkdirSync(dir, {recursive: true});
  const build = spawnSync('c++', ['-std=c++17', '-framework', 'CoreFoundation', '-I', path.join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include'),
    path.join(root, 'tests/fixtures/browser-download-reservation-checks.cc'), '-o', path.join(dir, 'reservation')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(path.join(dir, 'reservation'), [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
test('real Swift download lifecycle, origin-only history and retryable native consent', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/download-permissions-repair');
  fs.mkdirSync(dir, {recursive: true});
  const files = ['App/Sources/Tatwo2/Browser/BrowserDownloadStore.swift', 'App/Sources/Tatwo2/Browser/BrowserHumanInteraction.swift', 'tests/fixtures/browser-download-permissions-checks.swift'];
  const source = files.map(p => fs.readFileSync(path.join(root, p), 'utf8').replace('import TatwoCEFBridge', '')).join('\n');
  fs.writeFileSync(path.join(dir, 'fixture.swift'), source);
  const build = spawnSync('swiftc', ['-parse-as-library', path.join(dir, 'fixture.swift'), '-o', path.join(dir, 'fixture')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(path.join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PASS: consent coalescing/);
});

test('stage the real CEF download fixture and raw selftest loader', {skip: process.env.TATWO_ENABLE_CEF !== '1'}, () => {
  const binary = process.env.TATWO2_TEST_BINARY;
  assert.ok(binary && process.env.TATWO_CEF_ROOT, 'real CEF binary and runtime required');
  const receipt = path.join(testScratch('w258-loader-'), 'cef-app.json');
  const stage = spawnSync(process.execPath, [path.join(root, 'tests/fixtures/w258-stage.mjs')], {
    cwd: root, encoding: 'utf8', timeout: 120000,
    env: {...process.env, TATWO2_W258_CEF_RECEIPT: receipt},
  });
  assert.equal(stage.status, 0, stage.stdout + stage.stderr);
  const app = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  assert.ok(fs.existsSync(app.binary));
});
