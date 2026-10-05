import { testScratch } from './helpers/test-scratch.mjs';
import { CLI_RESOURCE_WAIT_MS, waitForCLIResources } from './helpers/cli-resource-readiness.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const files = [
  'App/Sources/Tatwo2/CLI/CLIWorkbenchLayout.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchPresentation.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchTheme.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchSurface.swift',
  'App/Sources/Tatwo2/Fixture/CLIWorkbenchFixture.swift',
];
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');

// The native build and compiler-free negative probes use the same guards.
// Keep their order, paths, thresholds and exit code unchanged.
const nativePreflight = String.raw`
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level) || :
[[ "$pressure" == 1 ]] || {
  printf 'RESOURCE_PAUSE: memory pressure actual=%s required=1; compile not started (exit 75)\n' "$pressure" >&2
  exit 75
}
system_free_kib=$(df -k / | tail -1 | awk '{print $4}') || :
[[ "$system_free_kib" -ge 10485760 ]] || {
  printf 'RESOURCE_PAUSE: system volume / available_kib=%s required_kib=10485760 (10 GiB); compile not started (exit 75)\n' "$system_free_kib" >&2
  exit 75
}
work_free_kib=$(df -k . | tail -1 | awk '{print $4}') || :
[[ "$work_free_kib" -ge 20971520 ]] || {
  printf 'RESOURCE_PAUSE: work volume repo=%s available_kib=%s required_kib=20971520 (20 GiB); compile not started (exit 75)\n' "$PWD" "$work_free_kib" >&2
  exit 75
}
`;

for (const [name, pressure, system, work, expected] of [
  ['memory warning', 2, 1153433, 1, /memory pressure actual=2 required=1/],
  ['memory critical', 4, 10485760, 20971520, /memory pressure actual=4 required=1/],
  ['mini system space', 1, 1153433, 1, /system volume \/ available_kib=1153433 required_kib=10485760 \(10 GiB\)/],
  ['system threshold minus one', 1, 10485759, 20971520, /available_kib=10485759 required_kib=10485760/],
  ['work threshold minus one', 1, 10485760, 20971519, /work volume repo=.* available_kib=20971519 required_kib=20971520 \(20 GiB\)/],
  ['exact thresholds', 1, 10485760, 20971520, null],
]) {
  test(`CLI workbench preflight: ${name} (no compiler)`, () => {
    const result = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
sysctl() { printf '%s\\n' "$FIXTURE_PRESSURE"; }
df() {
  case "$2" in
    /) printf 'fixture 0 0 %s 0%% /\\n' "$FIXTURE_SYSTEM_KIB" ;;
    .) printf 'fixture 0 0 %s 0%% /fixture\\n' "$FIXTURE_WORK_KIB" ;;
    *) return 90 ;;
  esac
}
${nativePreflight}
printf 'PREFLIGHT_PASSED_NO_COMPILER\\n'
`], {
      cwd: repo, encoding: 'utf8', timeout: 5000,
      env: { ...process.env, FIXTURE_PRESSURE: String(pressure),
        FIXTURE_SYSTEM_KIB: String(system), FIXTURE_WORK_KIB: String(work) },
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, expected ? 75 : 0, result.stderr);
    if (expected) {
      assert.match(result.stderr, expected);
      assert.match(result.stderr, /RESOURCE_PAUSE: .*compile not started \(exit 75\)/);
      assert.equal(result.stdout, '', 'blocked preflight must not reach the build continuation');
    } else {
      assert.equal(result.stderr, '');
      assert.equal(result.stdout, 'PREFLIGHT_PASSED_NO_COMPILER\n');
    }
  });
}

test('CLI workbench presentation has one action seam and no runtime or store dependency', () => {
  for (const name of files) {
    assert.doesNotMatch(read(name), /import SwiftTerm|Process\(|FileManager|UserDefaults|URLSession|forkpty|ProcessInfo|cliSessionsStore/,
      name);
  }
  const view = read(files[3]);
  assert.match(view, /let send: \(CLIWorkbenchAction\) -> Void/);
  assert.match(view, /@ViewBuilder let terminal:/);
  assert.doesNotMatch(view, /frame\(maxWidth: 700\)|height: (300|600)|CLISolidCard/);
  assert.match(view, /allowsHitTesting\(placement.isVisible\)/);
  assert.match(view, /accessibilityHidden\(!placement.isVisible\)/);
  assert.match(view, /CLIWorkbenchMetrics.dividerHit|CLIWorkbenchDividerHandle/);
  assert.match(read(files[1]), /deleteToLineStart = false/);
  assert.match(read(files[1]), /deletePreviousWord = false/);
  const rail = view.slice(view.indexOf('struct CLIWorkbenchSessionRows'));
  assert.match(rail, /ForEach\(tabs\)/);
  assert.match(rail, /send\(\.selectTab\(tab.id\)\)/);
  assert.match(rail, /historyExpanded = false/);
  assert.match(rail, /if historyExpanded/);
  assert.doesNotMatch(rail, /Text\(pane.statusLabel\)|工作台窗格/);
});

test('CLI workbench native fixture: layout, actions and fixed visual set', { timeout: 180_000 + CLI_RESOURCE_WAIT_MS }, async t => {
  if (process.platform !== 'darwin') return t.skip('native fixture requires macOS');
  if (process.env.TATWO_CLI_UI_RENDER !== '1') return t.skip('opt-in native UI compile; run with TATWO_CLI_UI_RENDER=1');
  const { samples, elapsedMs } = await waitForCLIResources(repo);
  t.diagnostic(`CLI_RESOURCE_READY samples=${samples} elapsedMs=${elapsedMs}`);
  const pressure = spawnSync('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level'], { encoding: 'utf8' });
  assert.equal(pressure.stdout.trim(), '1',
    `RESOURCE_PAUSE: memory pressure actual=${pressure.stdout.trim()} required=1; native fixture not compiled`);
  const scratch = testScratch('cli-native-');
  fs.mkdirSync(scratch, { recursive: true }); // ONE reusable slot, no mkdtemp or extra App bundle.
  const inputs = [
    'App/Sources/Tatwo2/Visual/TatwoTheme.swift',
    'App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift',
    'App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift',
    ...files,
    'tests/fixtures/cli-workbench-checks.swift',
  ];
  const source = inputs.map(read).join('\n');
  fs.writeFileSync(path.join(scratch, 'main.swift'), source);
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
${nativePreflight}
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 30 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun swiftc -j 2 "$1" -o "$2"
`, 'cli-workbench-fixture', path.join(scratch, 'main.swift'), path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 110_000,
    env: { ...process.env, TMPDIR: scratch },
  });
  fs.writeFileSync(path.join(scratch, 'build.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stderr || build.error?.message ||
    `CLI fixture build exited status=${build.status} signal=${build.signal ?? 'none'}; see ${path.join(scratch, 'build.log')}`);
  const run = spawnSync(path.join(scratch, 'checks'), [scratch], {
    cwd: scratch, encoding: 'utf8', timeout: 45_000,
    env: { HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin' },
  });
  fs.writeFileSync(path.join(scratch, 'run.log'), run.stdout + run.stderr);
  process.stdout.write(run.stdout);
  const hash = name => createHash('sha256').update(fs.readFileSync(path.join(scratch, name))).digest('hex');
  fs.writeFileSync(path.join(scratch, 'metadata.json'), JSON.stringify({
    surface: 'CLI workbench, native pure UI fixture; no production terminal',
    reference: 'Seedmux 0.1.41 (build 42), frozen at Goal start',
    timestamp: new Date().toISOString(),
    sourceSHA256: createHash('sha256').update(source).digest('hex'),
    files: Object.fromEntries(inputs.map(name => [name, createHash('sha256').update(read(name)).digest('hex')])),
    images: Object.fromEntries(fs.readdirSync(scratch).filter(name => name.endsWith('.png')).map(name => [name, hash(name)])),
    productionWiring: false, humanApproval: false, terminalAcceptance: false,
  }, null, 2));
  process.stdout.write(`CLI_WORKBENCH_PREVIEW ${scratch}\n`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
