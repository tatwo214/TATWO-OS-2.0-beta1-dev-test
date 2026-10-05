import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { CLI_RESOURCE_WAIT_MS, readCLIResourceSample, waitForCLIResources } from './helpers/cli-resource-readiness.mjs';

const ready = { pressure: '1', systemKiB: '10485760', workKiB: '20971520', errors: [] };

// Pure synthetic time and readings: no system probes, sleeps, locks or compiler.
function sequence(readings, { probeMs = 0, oversleepMs = 0 } = {}) {
  let time = 0;
  let calls = 0;
  const pauses = [];
  return {
    options: {
      now: () => time,
      readSample: deadline => {
        assert.equal(deadline, CLI_RESOURCE_WAIT_MS);
        const sample = readings[Math.min(calls++, readings.length - 1)];
        time += probeMs;
        if (sample instanceof Error) throw sample;
        return sample;
      },
      pause: async ms => { pauses.push(ms); time += ms + oversleepMs; },
    },
    calls: () => calls, time: () => time, pauses,
  };
}

test('CLI readiness: recovery requires two consecutive exact-threshold samples', async () => {
  const fixture = sequence([
    { ...ready, systemKiB: '4598540' }, ready,
    { ...ready, workKiB: '20971519' }, ready, ready,
  ]);
  assert.deepEqual(await waitForCLIResources('/synthetic', fixture.options), { samples: 5, elapsedMs: 20000 });
  assert.equal(fixture.calls(), 5);
  assert.deepEqual(fixture.pauses, [5000, 5000, 5000, 5000]);
});

for (const [field, values] of [
  ['pressure', ['2', '4', '', '01', '1\n', undefined]],
  ['systemKiB', ['10485759', '', 'NaN', 'Infinity', '-1', '10485760oops', '1e8', '9007199254740992', undefined]],
  ['workKiB', ['20971519', '', ' ', '20971520.0', '-1', null, 20971520]],
]) {
  test(`CLI readiness: invalid/below-threshold ${field} resets consecutive samples`, async () => {
    for (const value of values) {
      const fixture = sequence([ready, { ...ready, [field]: value }, ready, ready]);
      assert.equal((await waitForCLIResources('/synthetic', fixture.options)).samples, 4, String(value));
    }
  });
}

test('CLI readiness: errors and missing readings cannot authorize compilation', async () => {
  for (const bad of [undefined, {}, { ...ready, errors: ['df failed'] }, new Error('probe failed')]) {
    const fixture = sequence([ready, bad, ready, ready]);
    assert.equal((await waitForCLIResources('/synthetic', fixture.options)).samples, 4);
  }
});

test('CLI readiness: timeout reports last actual values, unchanged thresholds and deadline', async () => {
  const fixture = sequence([{ pressure: '4', systemKiB: '4598540', workKiB: '19', errors: [] }]);
  await assert.rejects(waitForCLIResources('/synthetic', fixture.options), error => {
    for (const text of ['RESOURCE_PAUSE:', 'deadline=120000ms', 'elapsed_ms=120000',
      'actual="4" required=1', 'available_kib="4598540" required_kib=10485760 (10 GiB)',
      'repo=/synthetic available_kib="19" required_kib=20971520 (20 GiB)',
      'compile not started (exit 75)']) assert.ok(error.message.includes(text), error.message);
    return true;
  });
  assert.equal(fixture.calls(), 24);
  assert.equal(fixture.time(), CLI_RESOURCE_WAIT_MS);
});

test('CLI readiness: permanent invalid reading/probe failure remains a detailed failure', async () => {
  for (const bad of [{ ...ready, systemKiB: '' }, new Error('unreadable probe')]) {
    const fixture = sequence([bad]);
    await assert.rejects(waitForCLIResources('/synthetic', fixture.options), /RESOURCE_PAUSE:.*(?:available_kib=""|unreadable probe).*compile not started/);
  }
});

test('CLI readiness: one good sample or a late second sample is not sufficient', async () => {
  // First probe takes 116s, leaving only 4s to sleep; never start a late probe.
  const one = sequence([ready], { probeMs: 116000 });
  await assert.rejects(waitForCLIResources('/synthetic', one.options), /consecutive_valid=1\/2/);
  assert.deepEqual(one.pauses, [4000]);
  assert.equal(one.calls(), 1);
  // Second otherwise-valid probe completes exactly at, or beyond, the deadline.
  for (const probeMs of [57500, 58000]) {
    const late = sequence([ready], { probeMs });
    await assert.rejects(waitForCLIResources('/synthetic', late.options), /RESOURCE_PAUSE:/);
    assert.equal(late.calls(), 2);
  }
  const stalled = sequence([ready], { oversleepMs: 120000 });
  await assert.rejects(waitForCLIResources('/synthetic', stalled.options), /RESOURCE_PAUSE:/);
  assert.equal(stalled.calls(), 1);
});

test('CLI resource probes: correct volumes, cwd and shared deadline; no shell/compiler', () => {
  let time = 0;
  const calls = [];
  const sample = readCLIResourceSample('/synthetic', 2500, {
    now: () => time,
    run: (command, args, options) => {
      calls.push([command, args, options]);
      time += 1000;
      return { status: 0, stdout: calls.length === 1 ? '1\n' :
        `Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 99 1 ${calls.length === 2 ? 10485760 : 20971520} 1% /work volume\n` };
    },
  });
  assert.deepEqual(sample, ready);
  assert.deepEqual(calls.map(([command, args]) => [command, args]), [
    ['/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']],
    ['/bin/df', ['-k', '/']], ['/bin/df', ['-k', '.']],
  ]);
  assert.deepEqual(calls.map(([, , options]) => options.timeout), [1000, 1000, 500]);
  for (const [, , options] of calls) {
    assert.equal(options.cwd, '/synthetic');
    assert.equal(options.killSignal, 'SIGKILL');
    assert.equal(options.shell, undefined);
  }
});

test('CLI resource probes: expired deadlines do not spawn, command failures stay invalid', () => {
  const expired = readCLIResourceSample('/synthetic', 100, {
    now: () => 100, run: () => assert.fail('must not spawn after deadline'),
  });
  assert.equal(expired.errors.length, 3);
  assert.equal(expired.systemKiB, '');
  const failed = readCLIResourceSample('/synthetic', 1000, {
    now: () => 0,
    run: () => ({ status: null, error: new Error('ETIMEDOUT'), stdout: '', stderr: 'probe failed' }),
  });
  assert.equal(failed.errors.length, 3);
  assert.match(failed.errors.join(' '), /ETIMEDOUT.*probe failed/);
});

test('CLI readiness is before the existing native guards/build, with original budgets added', () => {
  const source = fs.readFileSync(new URL('./tatwo2-cli-workbench.test.mjs', import.meta.url), 'utf8');
  const native = source.slice(source.indexOf("test('CLI workbench native fixture:"));
  assert.match(native, /timeout: 180_000 \+ CLI_RESOURCE_WAIT_MS/);
  assert.equal(native.match(/await waitForCLIResources\(repo\)/g)?.length, 1);
  const readinessDiagnostic = [
    'const { samples, elapsedMs } = await waitForCLIResources(repo);',
    '  t.diagnostic(`CLI_RESOURCE_READY samples=${samples} elapsedMs=${elapsedMs}`);',
  ].join('\n');
  assert.ok(native.includes(readinessDiagnostic), 'report only sample count and elapsed time after readiness succeeds');
  assert.equal(native.match(/t\.diagnostic\(/g)?.length, 1);
  assert.ok(native.indexOf('await waitForCLIResources(repo)') < native.indexOf("spawnSync('/usr/sbin/sysctl'"));
  assert.ok(native.indexOf('await waitForCLIResources(repo)') < native.indexOf("testScratch('cli-native-')"));
  assert.match(native, /timeout: 110_000/);
  assert.match(native, /timeout: 45_000/);
  assert.equal(native.match(/xcrun swiftc/g)?.length, 1);
  assert.equal(native.match(/const run = spawnSync/g)?.length, 1);
  assert.match(native, /\$\{nativePreflight\}\nreceipt=/);
});
