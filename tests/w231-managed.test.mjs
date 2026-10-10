import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runIsolated } from './helpers/w187-runtime.mjs';

test('W231 managed read, trading read-only and group transport gates use actual facades', { timeout: 240_000 }, () => {
  const { output } = runIsolated('w231managed');
  assert.match(output, /W231 SUMMARY passed=\d+ failures=0/);
  for (const label of ['normal session readable', 'trading session readable', 'trading writable workspace refused',
    'managed mention creates no group', 'normal group reaches synthetic TAP', 'queued TAP transport rechecks managed marker']) {
    assert.ok(output.includes(`W231 PASS ${label}`), label);
  }
});

test('W231 refuses managed reads before obtaining transcript or decoding cursors', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/HandsService.swift', 'utf8');
  const body = source.slice(source.indexOf('func readSession('));
  const guard = body.indexOf('controllerCreatorFingerprint == nil');
  assert.ok(guard >= 0 && guard < body.indexOf('handsSessionSnapshot(id)'));
  assert.ok(body.indexOf('session_not_found_or_not_allowed') < body.indexOf('if let cursor'));
});

test('W231 retains browsing refusal before DM source mutation', () => {
  const source = readFileSync('App/Sources/Tatwo2/DM/GlobalDMStore.swift', 'utf8');
  const body = source.slice(source.indexOf('func send() -> Bool'));
  assert.ok(body.indexOf('guard !isBrowsing') < body.indexOf('OSEventSources.begin('));
});

test('W231 retains managed approval restriction and sidecar PID/start-time checks', () => {
  const engine = readFileSync('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift', 'utf8');
  const sidecar = readFileSync('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift', 'utf8');
  assert.match(engine, /legacyCodexAutoApprove: !controlled && autoApprove && engine == \.codex/);
  assert.match(engine, /if let s = sidecars\[threadID\], s\.isRunning,/);
  assert.match(engine, /s\.processIdentifier\.flatMap\(\{ OSSocketCaller\.processStartTime\(\$0\) \}\)\.map\(\{ \$0 == s\.processStartTime \}\) == true/);
  assert.match(sidecar, /var isRunning: Bool \{ startTime != nil && OSSocketCaller\.processStartTime\(pid\) == startTime \}/);
});
