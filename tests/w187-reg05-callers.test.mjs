import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import { dualPinOptions } from '../Engines/gbrain-adapter/ssh-pins.mjs';

const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const facade = n => read('App/Sources/Tatwo2/Facade/' + n + '.swift');
const scripts = ['tatwo-data-sync', 'tatwo-skillet-md', 'tatwo-os-image', 'tatwo-device-sync',
  'tatwo-device-enroll', 'tatwo-remote-channel-sync', 'tatwo-lint-lane', 'tatwo-distributed-run'];

test('REG-05 every production caller reaches dual-source validation before launching SSH/SCP/rsync', () => {
  for (const n of ['DispatchEngine', 'RemoteEngineSync', 'PeerUpdateSource']) {
    assert.match(facade(n), /DeviceFleetSSHPins\.withEnvironment[\s\S]*SSHHostPin\.make[^\n]*environment: \$0/);
  }
  for (const n of ['RemoteHostLink', 'EngineMemoryLinks', 'DeviceFleetGate', 'DevicePairingClient']) {
    assert.match(facade(n), /DeviceFleetSSHPins\.lines/);
  }
  const sidecar = read('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift');
  assert.match(sidecar, /let pin = try DeviceFleetSSHPins\.withEnvironment[\s\S]*arguments = pin\.options \+ launch\.arguments[\s\S]*remoteHostPin = pin/);
  assert.match(read('Engines/gbrain-adapter/server.mjs'), /\.\.\.dualPinOptions\(config\.host, config\.sshPort \?\? 22\)/);
  assert.equal((read('Engines/gbrain-adapter/service.mjs').match(/sshArguments\(config\)/g) ?? []).length, 4);
  for (const name of scripts) {
    const s = read(`scripts/${name}.sh`);
    execFileSync('/bin/bash', ['-n', `scripts/${name}.sh`]);
    assert.match(s, /source .*tatwo-ssh-pins\.sh/);
    assert.match(s, /tatwo_pinned_run/);
    for (const line of s.split('\n').filter(l => !l.trim().startsWith('#'))) {
      assert.doesNotMatch(line, /(?:^|\|\s|\$\()ssh -|^\s*scp -|^\s*"\$(?:SSH|SCP)_CMD" /, `${name}: uncomposed transport`);
    }
    if (['tatwo-device-sync', 'tatwo-remote-channel-sync'].includes(name)) assert.match(s, /tatwo_ssh_transport/);
  }
  assert.doesNotMatch(read('scripts/tatwo-remote-channel-sync.sh'), /StrictHostKeyChecking=accept-new/);
  assert.match(facade('DeviceRegistry'), /pinConflicts = Array\(Set/);
  execFileSync('/bin/bash', ['-n', 'scripts/tatwo-ssh-pins.sh']);
  assert.match(read('scripts/build-app.sh'), /Engines\/gbrain-adapter\/ssh-pins\.mjs/);
});

function fixture() {
  const root = testScratch('w187-reg05-');
  for (const k of ['a', 'b']) execFileSync('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', 'fixture', '-f', join(root, k)]);
  const key = k => readFileSync(join(root, k + '.pub'), 'utf8').trim().split(' ').slice(0, 2).join(' ');
  const known = join(root, 'user known_hosts'), fleet = join(root, 'fleet-known-hosts');
  const env = { ...process.env, HOME: root, TATWO2_LIVE_ROOT: root, TATWO2_SSH_KNOWN_HOSTS: known };
  return { root, key, known, fleet, env };
}

test('REG-05 shared script/GBrain policy: either source, duplicate, conflict, hashed host, revoked key, unknown host', () => {
  const f = fixture();
  writeFileSync(f.known, ''); writeFileSync(f.fleet, `peer.invalid ${f.key('a')}\n`);
  let opts = dualPinOptions('peer.invalid', 22, f.env);
  assert.ok(opts.includes('StrictHostKeyChecking=yes'));
  const parsed = spawnSync('/usr/bin/ssh', ['-F', '/dev/null', '-G', ...opts, 'peer.invalid'], { env: f.env, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.ok(parsed.stdout.includes(f.known) && parsed.stdout.includes(f.fleet));
  assert.ok(opts.includes(`UserKnownHostsFile="${f.known}" "${f.fleet}"`));
  writeFileSync(f.known, `peer.invalid ${f.key('a')}\n`); writeFileSync(f.fleet, '');
  assert.doesNotThrow(() => dualPinOptions('peer.invalid', 22, f.env));
  writeFileSync(f.fleet, `peer.invalid ${f.key('a')}\n`);
  assert.doesNotThrow(() => dualPinOptions('peer.invalid', 22, f.env));
  writeFileSync(f.known, `peer.invalid ${f.key('b')}\n`);
  assert.throws(() => dualPinOptions('peer.invalid', 22, f.env), /pin_conflict/);
  execFileSync('/usr/bin/ssh-keygen', ['-H', '-f', f.known], { stdio: 'ignore' });
  assert.throws(() => dualPinOptions('peer.invalid', 22, f.env), /pin_conflict/);
  writeFileSync(f.known, `@revoked elsewhere.invalid ${f.key('a')}\n`);
  assert.throws(() => dualPinOptions('peer.invalid', 22, f.env), /pin_conflict/);
  writeFileSync(f.known, '');
  assert.throws(() => dualPinOptions('unknown.invalid', 22, f.env), /paired_host_key_not_found/);
  writeFileSync(f.fleet, `[peer.invalid]:2222 ${f.key('a')}\n`);
  assert.doesNotThrow(() => dualPinOptions('peer.invalid', 2222, f.env));
  assert.throws(() => dualPinOptions('-oProxyCommand=bad', 22, f.env), /invalid_ssh_target/);
});

test('REG-05 shell wrapper refuses before executing a fake transport and preserves argv with spaces', () => {
  const f = fixture(), marker = join(f.root, 'launched');
  const fake = join(f.root, 'transport');
  writeFileSync(fake, '#!/bin/bash\nprintf "%s\\n" "$@" > "$REG05_MARKER"\n', { mode: 0o700 });
  writeFileSync(f.known, `peer.invalid ${f.key('a')}\n`); writeFileSync(f.fleet, `peer.invalid ${f.key('b')}\n`);
  const cmd = 'source scripts/tatwo-ssh-pins.sh; tatwo_pinned_run peer.invalid "$REG05_FAKE" peer.invalid echo ok';
  let result = spawnSync('/bin/bash', ['-c', cmd], { env: { ...f.env, REG05_FAKE: fake, REG05_MARKER: marker }, encoding: 'utf8' });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /REG-05 pin_rejected/); assert.ok(!existsSync(marker));
  writeFileSync(f.fleet, `peer.invalid ${f.key('a')}\n`);
  result = spawnSync('/bin/bash', ['-c', cmd], { env: { ...f.env, REG05_FAKE: fake, REG05_MARKER: marker }, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(readFileSync(marker, 'utf8').split('\n').includes(`UserKnownHostsFile="${f.known}" "${f.fleet}"`));
});

test('REG-05 rsync -e parser preserves both pin paths with spaces using only a fake SSH process', () => {
  const f = fixture(), fake = join(f.root, 'transport'), marker = join(f.root, 'argv');
  writeFileSync(fake, '#!/bin/bash\nprintf "%s\\n" "$@" > "$REG05_MARKER"\n', { mode: 0o700 });
  writeFileSync(f.known, `peer.invalid ${f.key('a')}\n`); writeFileSync(f.fleet, '');
  const transport = spawnSync('/bin/bash', ['-c', 'source scripts/tatwo-ssh-pins.sh; tatwo_ssh_transport peer.invalid'], { env: f.env, encoding: 'utf8' });
  assert.equal(transport.status, 0, transport.stderr);
  const result = spawnSync('/usr/bin/rsync', ['-e', transport.stdout.replace('/usr/bin/ssh', fake), 'peer.invalid:/fixture', join(f.root, 'output')],
    { env: { ...f.env, REG05_MARKER: marker }, encoding: 'utf8', timeout: 5000 });
  assert.ok(!result.error, String(result.error));
  assert.ok(existsSync(marker), result.stderr);
  assert.ok(readFileSync(marker, 'utf8').split('\n').includes(`UserKnownHostsFile="${f.known}" "${f.fleet}"`));
});
