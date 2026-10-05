import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmdirSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const runTimeout = cmd => basename(cmd) === 'codesign' ? 30_000 : 120_000;
const run = (cmd, args, env = {}, timeout = runTimeout(cmd)) => {
  // Tests may shorten the deadline, never disable or increase it.
  assert.ok(Number.isInteger(timeout) && timeout > 0 && timeout <= runTimeout(cmd), 'invalid command timeout');
  const r = spawnSync(cmd, args, {
    encoding: 'utf8', env: { ...process.env, ...env }, timeout,
    // A fixture waiting on SecurityAgent must not ignore the timeout's SIGTERM.
    // This targets only the child spawned here, not any existing signer or agent.
    killSignal: 'SIGKILL',
  });
  assert.ok(!r.error && r.signal == null && r.status === 0, [
    `command=${JSON.stringify([cmd, ...args])} timeout=${timeout}ms`,
    `status=${r.status} signal=${r.signal ?? 'none'}`,
    `error=${r.error ? `${r.error.code ?? r.error.name}: ${r.error.message}` : 'none'}`,
    `stdout:\n${r.stdout ?? ''}`, `stderr:\n${r.stderr ?? ''}`,
  ].join('\n'));
  return r.stdout;
};

const selectSignIdentity = (validInventory, requested) => {
  // Preserve the historical first-SHA selection only when no explicit pin exists.
  if (requested === undefined) return validInventory.match(/\b([A-F0-9]{40})\b/)?.[1];
  assert.ok(typeof requested === 'string' && requested.length === 40 && /^[A-Fa-f0-9]{40}$/.test(requested),
    'TATWO_TEST_SIGN_IDENTITY must be a full 40-character hexadecimal SHA; names, prefixes and whitespace are not accepted');
  // security find-identity -v supplies valid identities. Match a complete numbered
  // inventory entry, not a SHA in a warning/name or an entry with an error suffix.
  // Hex case is canonicalized; no trimming, name lookup or fallback is permitted.
  const pin = requested.toUpperCase();
  const identities = [...validInventory.matchAll(/^[ \t]*\d+\)[ \t]+([A-F0-9]{40})[ \t]+"[^"\r\n]*"[ \t]*\r?$/gm)]
    .map(match => match[1]);
  const matches = identities.filter(identity => identity === pin).length;
  assert.equal(matches, 1,
    `TATWO_TEST_SIGN_IDENTITY must match exactly one valid codesigning identity (matches=${matches}); refusing fallback`);
  return pin;
};

// Pure synthetic inventory tests: never query Keychain or sign a fixture.
test('sign identity selector: no pin preserves first identity and absent-certificate behavior', () => {
  const first = 'A'.repeat(40), second = 'B'.repeat(40);
  const inventory = `  1) ${first} "Fixture other"\n  2) ${second} "Fixture App"\n     2 valid identities found\n`;
  assert.equal(selectSignIdentity(inventory, undefined), first);
  assert.equal(selectSignIdentity('     0 valid identities found\n', undefined), undefined);
});

test('sign identity selector: an explicit full SHA selects the matching second valid identity', () => {
  const first = 'A'.repeat(40), second = 'B'.repeat(40);
  const inventory = `  1) ${first} "Fixture other"\r\n  2) ${second} "Fixture App"\r\n     2 valid identities found\r\n`;
  assert.equal(selectSignIdentity(inventory, second), second);
  assert.equal(selectSignIdentity(inventory, second.toLowerCase()), second);
});

test('sign identity selector: malformed or empty pins fail instead of using the first identity', () => {
  const sha = 'A'.repeat(40);
  const inventory = `  1) ${sha} "Fixture App"\n     1 valid identities found\n`;
  for (const pin of ['', '-', 'Fixture App', sha.slice(1), sha + 'A', 'G'.repeat(40), ' ' + sha, sha + '\n']) {
    assert.throws(() => selectSignIdentity(inventory, pin), /TATWO_TEST_SIGN_IDENTITY must be a full 40-character hexadecimal SHA/);
  }
});

test('sign identity selector: missing pins, warning/name hashes and invalid entries fail closed', () => {
  const first = 'A'.repeat(40), missing = 'B'.repeat(40);
  for (const inventory of [
    '     0 valid identities found\n',
    `  1) ${first} "Fixture other"\n     1 valid identities found\n`,
    `  1) ${first} "Fixture label ${missing}"\nwarning: ${missing}\n`,
    `  1) ${missing} "Fixture invalid" (CSSMERR_TP_CERT_EXPIRED)\n`,
    `  1) ${missing}A "Fixture longer hash"\n`,
  ]) {
    assert.throws(() => selectSignIdentity(inventory, missing), /matches=0.*refusing fallback/);
  }
});

test('sign identity selector: duplicate matches fail closed rather than choosing an ambiguous entry', () => {
  const sha = 'A'.repeat(40);
  const inventory = `  1) ${sha} "Fixture one"\n  2) ${sha} "Fixture two"\n     2 valid identities found\n`;
  assert.throws(() => selectSignIdentity(inventory, sha), /matches=2.*refusing fallback/);
});

// Run these alone with --test-name-pattern='^run helper:'; no signing/Keychain calls.
test('run helper: codesign has a 30s ceiling and other commands have a 120s ceiling', () => {
  for (const cmd of ['codesign', '/usr/bin/codesign']) assert.equal(runTimeout(cmd), 30_000);
  for (const cmd of ['security', 'python3', '/usr/bin/ditto', process.execPath]) assert.equal(runTimeout(cmd), 120_000);
  for (const timeout of [0, -1, Infinity, NaN, 120_001]) {
    assert.throws(() => run(process.execPath, ['-e', 'process.exit(0)'], {}, timeout), /invalid command timeout/);
  }
  assert.throws(() => run('codesign', [], {}, 30_001), /invalid command timeout/);
});

test('run helper: a hanging child fails with timeout and signal diagnostics', () => {
  const started = Date.now();
  assert.throws(() => run(process.execPath, ['-e',
    'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000);',
  ], {}, 250), error => {
    assert.match(error.message, /timeout=250ms/);
    assert.match(error.message, /status=null signal=SIGKILL/);
    assert.match(error.message, /error=ETIMEDOUT:/);
    return true;
  });
  assert.ok(Date.now() - started < 5_000, 'hanging fixture must return promptly');
});

test('run helper: success preserves stdout and supplied environment', () => {
  assert.equal(run(process.execPath, ['-e', 'process.stdout.write(process.env.RUNTIME_HELPER_FIXTURE)'],
    { RUNTIME_HELPER_FIXTURE: 'fixture output' }), 'fixture output');
});

test('run helper: nonzero exit, signal and missing command fail with explicit diagnostics', () => {
  assert.throws(() => run(process.execPath, ['-e',
    'process.stdout.write("fixture stdout"); process.stderr.write("fixture stderr"); process.exit(7);',
  ]), error => {
    assert.match(error.message, /status=7 signal=none/);
    assert.match(error.message, /error=none/);
    assert.match(error.message, /stdout:\nfixture stdout/);
    assert.match(error.message, /stderr:\nfixture stderr/);
    return true;
  });
  assert.throws(() => run(process.execPath, ['-e', 'process.kill(process.pid, "SIGTERM");']),
    /status=null signal=SIGTERM/);
  assert.throws(() => run(join(root, 'absent-runtime-helper-command'), []), /error=ENOENT:/);
});

const hash = p => createHash('sha256').update(readFileSync(p)).digest('hex');
const sign = (p, extra = []) => run('codesign', ['--force', '--sign', '-', ...extra, p]);
const verify = p => run('codesign', ['--verify', '--deep', '--strict', p]);
const layer = (mode, app, ...args) => run('python3', [join(root, 'scripts/runtime-layer.py'), mode, app, ...args]);
const reuse = (app, baseline) => run('python3', [join(root, 'scripts/runtime-sign.py'), app, '-'], { TATWO2_RELEASE_BASELINE: baseline });
function fixture(dir) {
  const app = join(dir, 'TATWO OS.app');
  const contents = join(app, 'Contents');
  const framework = join(contents, 'Frameworks/Chromium Embedded Framework.framework');
  for (const path of ['MacOS', 'Resources/runtime/bin', 'Resources/claude-sidecar/node_modules/native', 'Frameworks/Chromium Embedded Framework.framework/Resources'])
    mkdirSync(join(contents, path), { recursive: true });
  const plist = (id, exe, type) => `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>${exe}</string><key>CFBundlePackageType</key><string>${type}</string></dict></plist>`;
  writeFileSync(join(contents, 'Info.plist'), plist('ai.tatwo.tatwo2', 'tatwo2', 'APPL'));
  writeFileSync(join(framework, 'Resources/Info.plist'), plist('example.runtime', 'Runtime', 'FMWK'));
  for (const p of ['MacOS/tatwo2', 'Resources/runtime/bin/node', 'Resources/claude-sidecar/node_modules/native/addon.node', 'Frameworks/Chromium Embedded Framework.framework/Runtime']) {
    copyFileSync('/usr/bin/true', join(contents, p)); if (p !== 'MacOS/tatwo2') sign(join(contents, p));
  }
  const worker = join(framework, 'XPCServices/Worker.xpc');
  mkdirSync(join(worker, 'Contents/MacOS'), { recursive: true });
  writeFileSync(join(worker, 'Contents/Info.plist'), plist('example.worker', 'Worker', 'XPC!'));
  copyFileSync('/usr/bin/true', join(worker, 'Contents/MacOS/Worker')); sign(worker);
  mkdirSync(join(framework, 'Resources/plain.bundle'));
  writeFileSync(join(framework, 'Resources/plain.bundle/data'), 'resource-only bundle');
  writeFileSync(join(framework, 'Resources/data'), 'unchanged');
  symlinkSync('node', join(contents, 'Resources/runtime/bin/link'));
  sign(framework); layer('prepare', app); sign(app); verify(app);
  return app;
}

test('real codesign: reuse, deterministic zip despite mtimes, sealed zero-difference reassembly', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w27-'));
  const baseline = fixture(join(dir, 'baseline'));
  const original = JSON.parse(readFileSync(join(baseline, 'Contents/Resources/runtime-layer.json'))).sha;
  const zipHashes = [];
  for (let n = 1; n <= 2; n++) {
    const app = join(dir, `candidate${n}/TATWO OS.app`);
    run('ditto', [baseline, app]);
    const framework = join(app, 'Contents/Frameworks/Chromium Embedded Framework.framework');
    // Replace only signature bytes; real codesign, no mocked signature/verification commands.
    if (n === 1) {
      run('codesign', ['--remove-signature', framework]);
      rmdirSync(join(framework, '_CodeSignature')); // Raw upstream bundle has no resource seal directory.
      const detached = join(dir, 'raw-code');
      copyFileSync(join(framework, 'Runtime'), detached);
      sign(detached, ['--identifier', 'example.runtime']);
      copyFileSync(detached, join(framework, 'Runtime'));
    } else sign(framework, ['--requirements', '=designated => identifier "example.runtime"']);
    assert.notEqual(hash(join(framework, 'Runtime')), hash(join(baseline, 'Contents/Frameworks/Chromium Embedded Framework.framework/Runtime')));
    utimesSync(join(app, 'Contents/Resources/runtime/bin/node'), 1700000000 + n * 500, 1700000000 + n * 500);
    const trace = reuse(app, baseline);
    assert.match(trace, /runtime reuse: Frameworks\/Chromium Embedded Framework.framework\n/);
    assert.match(trace, /runtime reuse: Resources\/runtime\/bin\/node/);
    assert.match(trace, /runtime reuse: Resources\/claude-sidecar\/node_modules\/native\/addon.node/);
    utimesSync(join(app, 'Contents/Resources/runtime/bin/node'), 1700000000 + n * 500, 1700000000 + n * 500);
    utimesSync(join(app, 'Contents/Resources/runtime'), 1700000000 + n * 500, 1700000000 + n * 500);
    layer('prepare', app); sign(app); verify(app);
    assert.equal(JSON.parse(readFileSync(join(app, 'Contents/Resources/runtime-layer.json'))).sha, original);
    const out = join(dir, `out${n}`); layer('split', app, out);
    const zip = join(out, `TATWO-OS-runtime-${original.slice(0, 12)}.zip`);
    zipHashes.push(hash(zip));
    const assembled = join(dir, `assembled${n}`);
    run('ditto', ['-x', '-k', join(out, 'TATWO-OS-app.zip'), assembled]);
    run('ditto', ['-x', '-k', zip, join(assembled, 'TATWO OS.app/Contents')]);
    verify(join(assembled, 'TATWO OS.app'));
    run('diff', ['-qr', app, join(assembled, 'TATWO OS.app')]);
  }
  assert.equal(zipHashes[0], zipHashes[1]);
});

test('changed resource, mode, entitlement, corrupt seal and wrong identity do not reuse bundle', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w27-negative-'));
  const baseline = fixture(join(dir, 'baseline'));
  for (const scenario of ['resource', 'binary', 'mode', 'entitlement', 'nested-entitlement', 'hardened', 'corrupt', 'identity', 'missing', 'dr-text']) {
    const app = join(dir, scenario, 'TATWO OS.app'); run('ditto', [baseline, app]);
    const fw = 'Contents/Frameworks/Chromium Embedded Framework.framework';
    const b = join(dir, `${scenario}-base/TATWO OS.app`); run('ditto', [baseline, b]);
    if (scenario === 'binary') copyFileSync('/usr/bin/false', join(app, fw, 'Runtime'));
    if (scenario === 'resource') writeFileSync(join(app, fw, 'Resources/data'), 'changed');
    if (scenario === 'mode') chmodSync(join(app, fw, 'Resources/data'), 0o755);
    if (scenario === 'corrupt') writeFileSync(join(b, fw, 'Resources/data'), 'tampered baseline');
    if (scenario === 'entitlement' || scenario === 'nested-entitlement') {
      const ent = join(dir, 'ent.plist');
      writeFileSync(ent, '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>');
      sign(join(app, fw, scenario === 'nested-entitlement' ? 'XPCServices/Worker.xpc' : ''), ['--entitlements', ent]);
      if (scenario === 'nested-entitlement') sign(join(app, fw));
    }
    if (scenario === 'hardened') sign(join(app, fw), ['--options', 'runtime']);
    if (scenario === 'identity') sign(join(b, fw), ['--identifier', 'different.identity']);
    const trace = reuse(app, scenario === 'missing' ? join(dir, 'absent') : scenario === 'dr-text' ? 'designated => ' + 'x'.repeat(300) : b);
    assert.ok(!trace.includes('runtime reuse: Frameworks/Chromium Embedded Framework.framework\n'), scenario);
    assert.match(trace, /runtime sign: Frameworks\/Chromium Embedded Framework.framework\n/);
    layer('prepare', app); sign(app); verify(app);
    if (scenario === 'nested-entitlement') assert.match(run('codesign', ['-d', '--entitlements', ':-', join(app, fw, 'XPCServices/Worker.xpc')]), /get-task-allow/);
    if (scenario === 'entitlement') assert.match(run('codesign', ['-d', '--entitlements', ':-', join(app, fw)]), /get-task-allow/);
    if (scenario === 'resource') assert.equal(readFileSync(join(app, fw, 'Resources/data'), 'utf8'), 'changed');
  }
});

test('real certificate cannot be reused under a requested ad-hoc identity', t => {
  const identities = run('security', ['find-identity', '-v', '-p', 'codesigning']);
  const cert = selectSignIdentity(identities, process.env.TATWO_TEST_SIGN_IDENTITY);
  if (!cert) return t.skip('no existing signing certificate; never create one in tests');
  const dir = mkdtempSync(join(tmpdir(), 'w27-cert-'));
  const baseline = fixture(join(dir, 'baseline'));
  const app = join(dir, 'candidate/TATWO OS.app'); run('ditto', [baseline, app]);
  const fw = 'Contents/Frameworks/Chromium Embedded Framework.framework';
  run('codesign', ['--force', '--sign', cert, '--timestamp=none', join(baseline, fw)]);
  const trace = reuse(app, baseline);
  assert.ok(!trace.includes('runtime reuse: Frameworks/Chromium Embedded Framework.framework\n'));
  assert.match(trace, /runtime sign: Frameworks\/Chromium Embedded Framework.framework\n/);
});

test('linker-signed Mach-O and CMS use the same normalized unsigned content', t => {
  const cert = selectSignIdentity(run('security', ['find-identity', '-v', '-p', 'codesigning']),
    process.env.TATWO_TEST_SIGN_IDENTITY);
  if (!cert) return t.skip('no existing signing certificate');
  const dir = mkdtempSync(join(tmpdir(), 'w27-linker-'));
  writeFileSync(join(dir, 'code.c'), 'int main(void) { return 0; }');
  run('xcrun', ['clang', join(dir, 'code.c'), '-o', join(dir, 'raw')]);
  copyFileSync(join(dir, 'raw'), join(dir, 'cms'));
  run('codesign', ['--force', '--sign', cert, '--timestamp=none', join(dir, 'cms')]);
  run('python3', ['-c', `import importlib.util, pathlib
s=importlib.util.spec_from_file_location('signer', ${JSON.stringify(join(root, 'scripts/runtime-sign.py'))})
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
assert m.stripped(pathlib.Path(${JSON.stringify(join(dir, 'raw'))})) == m.stripped(pathlib.Path(${JSON.stringify(join(dir, 'cms'))}))`]);
});

test('versioned frameworks follow real version directories, not Current symlink ancestors', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w27-versioned-'));
  const baseline = fixture(join(dir, 'baseline'));
  const fw = join(baseline, 'Contents/Frameworks/Chromium Embedded Framework.framework');
  mkdirSync(join(fw, 'Versions/A'), { recursive: true });
  for (const name of ['Runtime', 'Resources', 'XPCServices', '_CodeSignature'])
    renameSync(join(fw, name), join(fw, 'Versions/A', name));
  symlinkSync('A', join(fw, 'Versions/Current'));
  for (const name of ['Runtime', 'Resources', 'XPCServices']) symlinkSync(`Versions/Current/${name}`, join(fw, name));
  sign(fw); verify(fw);
  const app = join(dir, 'candidate/TATWO OS.app'); run('ditto', [baseline, app]);
  assert.match(reuse(app, baseline), /runtime reuse: Frameworks\/Chromium Embedded Framework.framework\n/);
  layer('prepare', app); sign(app); verify(app);
});

test('npm hidden lockfile drift adopts baseline bytes only when the node_modules tree is otherwise identical', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w31-lock-'));
  const baseline = fixture(join(dir, 'baseline'));
  const lockRel = 'Contents/Resources/claude-sidecar/node_modules/.package-lock.json';
  writeFileSync(join(baseline, lockRel), '{"baseline":true}');
  sign(baseline);
  for (const [name, extra, expectAdopt] of [['same', null, true], ['extra-file', 'Contents/Resources/claude-sidecar/node_modules/native/extra.txt', false]]) {
    const app = join(dir, `${name}/TATWO OS.app`);
    run('ditto', [baseline, app]);
    writeFileSync(join(app, lockRel), '{"baseline":false,"drift":"npm version"}');
    if (extra) writeFileSync(join(app, extra), 'new file');
    const out = reuse(app, baseline);
    assert.equal(readFileSync(join(app, lockRel), 'utf8') === '{"baseline":true}', expectAdopt, `${name}: ${out.stdout}`);
  }
});
