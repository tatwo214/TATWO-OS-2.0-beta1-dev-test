import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { testScratch } from './helpers/test-scratch.mjs';

test('W246 E1–E7 acceptance and identical Swift/JS URL corpus', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w246-tail-');
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  const at = name => path.join(root, name);
  const env = {
    ...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'),
    TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
    CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
    CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_SELFTEST: 'w246tail', W246_URL_CASES: at('urls.json'), TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const fake = ['ghp', 'W246_FAKE'].join('_'), atSign = String.fromCharCode(64);
  const cases = [
    [`https://fixture.invalid/mcp%2Fapi_key=${fake}`, true],
    [`https://fixture.invalid/mcp?x=one%26api_key=${fake}`, true],
    [`https://fixture.invalid/mcp%2F${fake}`, true],
    [`https://fixture.invalid/mcp#x=ok%26${fake}`, true],
    [`https://fixture.invalid%2Ftoken=${fake}`, true],
    ['https://user%40fixture.invalid/mcp', true],
    ...['%2F', '%3F', '%23'].map(separator => [`https://person${separator}note${atSign}fixture.invalid/mcp`, true]),
    ['https://fixture.invalid/path/unit@entry', false],
    ['https://[abc]/mcp', true], ['https://[::::]/mcp', true], ['https://[broken/mcp', true], ['https://fixture.invalid:bad/mcp', true],
    ['https://fixture.invalid:99999/mcp', true], ['https://', true],
    ['https://fixture.invalid/%GG', true], ['not a URL', true],
    ['https://fixture.invalid/a b', true],
    ['https://fixture.invalid/mcp', false], ['https://fixture.invalid/a%2Fb?x=a%26b#overview', false],
    ['https://fixture.invalid:443/mcp?mode=read', false], ['https://[::1]:8080/mcp', false],
  ];
  fs.writeFileSync(at('urls.json'), JSON.stringify(cases));
  for (const engine of ['claude', 'codex']) {
    const source = fs.readFileSync(`Engines/${engine}-sidecar/sidecar.mjs`, 'utf8');
    const start = source.indexOf('function secretURL('), end = source.indexOf('\n}', start) + 2;
    const secretURL = vm.runInNewContext(source.slice(start, end) + '\nsecretURL', { URL });
    assert.equal(secretURL(fake + '%GG'), true);
    assert.equal(secretURL('100%'), false);
    for (const [url, expected] of cases) assert.equal(secretURL(url, true), expected, `${engine}: ${url}`);
  }
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
  for (const phase of ['changed', 'confirm']) for (const scheme of ['light', 'dark']) assert.ok(fs.statSync(at(`artifacts/w246-${phase}-${scheme}.png`)).size > 1000);
});
