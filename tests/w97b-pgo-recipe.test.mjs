// W97b. The CEF recipe grew a PGO switch. These are static contracts on the
// recipe text and on what it prints in plan mode; they prove nothing about how
// fast the resulting browser is (that is docs/specs/097-browser-perf/).
// The point of (a) is that CEF_PGO unset must stay byte-for-byte the W94 build,
// so a PGO experiment can never silently change what the lead is packaging.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const recipe = path.join(root, 'scripts/build-cef-proprietary.sh');
const source = fs.readFileSync(recipe, 'utf8');

// Plan mode creates nothing and starts nothing, so it is safe to run here.
// The path is never touched: without --execute the script exits before any check.
const plan = env => execFileSync('bash', [recipe, '/Volumes/unused-plan-only/out'],
  { encoding: 'utf8', env: { ...process.env, ...env } });

const line = (text, key) => {
  const found = text.split('\n').find(one => one.startsWith(`${key}=`));
  assert.ok(found !== undefined, `${key} not printed`);
  return found.slice(key.length + 1);
};

const BASELINE_GN = 'proprietary_codecs=true ffmpeg_branding=Chrome '
  + 'is_official_build=true chrome_pgo_phase=0 enable_dsyms=false';

test('W97b (a) without CEF_PGO the build is the W94 one, word for word', () => {
  const out = plan({ CEF_PGO: '' });
  assert.equal(line(out, 'GN_DEFINES'), BASELINE_GN);
  assert.ok(line(out, 'OUTPUT').endsWith('_macosarm64_minimal.tar.bz2'), 'archive name changed');
  assert.ok(!out.includes('--with-pgo-profiles'), 'profiles fetched without being asked');
  // CEF_PGO set to anything but 1 is not a half-on state.
  assert.equal(line(plan({ CEF_PGO: '0' }), 'GN_DEFINES'), BASELINE_GN);
  assert.equal(line(plan({ CEF_PGO: 'true' }), 'GN_DEFINES'), BASELINE_GN);
});

test('W97b (b) CEF_PGO=1 turns on phase 2 and changes nothing else', () => {
  const gn = line(plan({ CEF_PGO: '1' }), 'GN_DEFINES');
  assert.equal(gn, BASELINE_GN.replace('chrome_pgo_phase=0', 'chrome_pgo_phase=2'));
});

test('W97b (c) CEF_PGO=1 also fetches the profiles, or ninja stops mid-build', () => {
  // Both the chrome mac-arm profile and the V8 builtins profile hang off the
  // single gclient var this flag sets; without it the build dies at
  // v8/tools/builtins-pgo/profiles/x64.profile.
  assert.ok(plan({ CEF_PGO: '1' }).includes('--with-pgo-profiles'));
});

test('W97b (d) the PGO archive gets its own name, beside the one in use', () => {
  const output = line(plan({ CEF_PGO: '1' }), 'OUTPUT');
  assert.ok(output.endsWith('_macosarm64_minimal-pgo.tar.bz2'), output);
  assert.notEqual(output, line(plan({ CEF_PGO: '' }), 'OUTPUT'));
});

test('W97b (e) the distribution directory inside the archive keeps the pinned name', () => {
  // tatwo-cef-bundle.sh copies the archive to the pinned file name and then
  // expects the pinned directory inside it; renaming NAME would break unpacking.
  assert.match(source, /^NAME="\$\{ARCHIVE%\.tar\.bz2\}"$/m);
  assert.match(source, /tar .* -cjf "\$OUTPUT\/\$OUT_ARCHIVE\.part" -C "\$DIST" "\$NAME"/);
});

test('W97b (f) the official-dylib replacement still runs, from archive or directory', () => {
  assert.match(source, /CEF_OFFICIAL_LIBS_DIR/);
  assert.match(source, /ctypes\.CDLL/);
  assert.match(source, /selfbuilt-misaligned/);
});
