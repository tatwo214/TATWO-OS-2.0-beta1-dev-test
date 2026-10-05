import { spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';

export const CLI_RESOURCE_WAIT_MS = 120_000;
const SAMPLE_INTERVAL_MS = 5_000;
const clock = () => performance.now();

// Only read resources. Each probe shares the readiness deadline; never compile,
// acquire a build lock, reclaim space, or retry a native fixture here.
export function readCLIResourceSample(repo, deadline, { now = clock, run = spawnSync } = {}) {
  const errors = [];
  function probe(command, args) {
    const remaining = Math.floor(deadline - now());
    if (remaining <= 0) {
      errors.push(`${command}: readiness deadline reached`);
      return '';
    }
    const result = run(command, args, {
      cwd: repo, encoding: 'utf8', timeout: Math.min(1_000, remaining),
      killSignal: 'SIGKILL', maxBuffer: 16 * 1024,
    });
    if (result.error || result.status !== 0) {
      errors.push(`${command}: ${result.error?.message ?? `status=${result.status} signal=${result.signal ?? 'none'}`} ${result.stderr ?? ''}`.trim());
    }
    return (result.stdout ?? '').trim();
  }
  const pressure = probe('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']);
  const available = target => probe('/bin/df', ['-k', target]).split('\n').at(-1).trim().split(/\s+/)[3] ?? '';
  return { pressure, systemKiB: available('/'), workKiB: available('.'), errors };
}

const validKiB = value => typeof value === 'string' && /^\d+$/.test(value) &&
  Number.isSafeInteger(Number(value));

export async function waitForCLIResources(repo, {
  now = clock,
  pause = sleep,
  readSample = deadline => readCLIResourceSample(repo, deadline, { now }),
} = {}) {
  const start = now();
  const deadline = start + CLI_RESOURCE_WAIT_MS;
  let consecutive = 0;
  let samples = 0;
  let last = {};
  while (now() < deadline) {
    try {
      last = readSample(deadline) ?? {};
    } catch (error) {
      last = { errors: [String(error)] };
    }
    samples++;
    const valid = last.pressure === '1' &&
      validKiB(last.systemKiB) && Number(last.systemKiB) >= 10485760 &&
      validKiB(last.workKiB) && Number(last.workKiB) >= 20971520 &&
      Array.isArray(last.errors) && last.errors.length === 0;
    consecutive = valid ? consecutive + 1 : 0;
    // A probe that finishes at/after the deadline cannot authorize compilation.
    if (now() >= deadline) break;
    if (consecutive === 2) return { samples, elapsedMs: now() - start };
    await pause(Math.min(SAMPLE_INTERVAL_MS, deadline - now()));
  }
  throw new Error(
    `RESOURCE_PAUSE: CLI readiness deadline=120000ms from wait start; elapsed_ms=${Math.ceil(now() - start)}; ` +
    `samples=${samples} consecutive_valid=${consecutive}/2; ` +
    `memory pressure actual=${JSON.stringify(last.pressure ?? '<unread>')} required=1; ` +
    `system volume / available_kib=${JSON.stringify(last.systemKiB ?? '<unread>')} required_kib=10485760 (10 GiB); ` +
    `work volume repo=${repo} available_kib=${JSON.stringify(last.workKiB ?? '<unread>')} required_kib=20971520 (20 GiB); ` +
    `probe_errors=${JSON.stringify(last.errors ?? [])}; compile not started (exit 75)`,
  );
}
