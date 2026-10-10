import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import { dualPinOptions } from '../Engines/gbrain-adapter/ssh-pins.mjs';
const source = n => readFileSync(`App/Sources/Tatwo2/${n}.swift`, 'utf8');
test('REV-01 revoked projections cannot poison owner apply', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /!roster.revoked.contains\(row.id\)/);
  assert.match(source('Facade/DeviceFleetRoster'), /fleet_projection_cache_rejected/);
});
test('PIN-02 mixed algorithms survive; same algorithm different key refuses', () => {
  const root = testScratch('w187-r2-pins-');
  const keys = {};
  for (const [name, type] of [['ed','ed25519'],['other','ed25519'],['ec','ecdsa'],['rsa','rsa']]) {
    execFileSync('/usr/bin/ssh-keygen', ['-q','-t',type,'-N','','-C','fixture','-f',join(root,name)]);
    keys[name] = readFileSync(join(root,name+'.pub'),'utf8').split(' ').slice(0,2).join(' ');
  }
  const known = join(root,'known_hosts');
  const env = { HOME: root, TATWO2_LIVE_ROOT: root, TATWO2_SSH_KNOWN_HOSTS: known };
  writeFileSync(known, Object.values(keys).filter(k => k !== keys.other).map(k => `peer.invalid ${k}`).join('\n')+'\n');
  assert.doesNotThrow(() => dualPinOptions('peer.invalid',22,env));
  writeFileSync(known, `peer.invalid ${keys.ed}\npeer.invalid ${keys.other}\n`);
  assert.throws(() => dualPinOptions('peer.invalid',22,env), /pin_conflict/);
});
test('PIN-02 config alias without literal pins falls back to OpenSSH resolution', () => {
  const root = testScratch('w187-r2-alias-');
  writeFileSync(join(root,'config'), 'Host work-alias\n HostName peer.invalid\n');
  const opts = dualPinOptions('work-alias',22,{ HOME: root, TATWO2_LIVE_ROOT: root, TATWO2_SSH_CONFIG: join(root,'config') });
  assert.ok(!opts.some(o => o.startsWith('HostKeyAlias=')));
  assert.ok(opts.includes('StrictHostKeyChecking=yes'));
});
test('PIN-02 config alias still rejects resolved same-algorithm conflicts', () => {
  const root = testScratch('w187-r2-alias-conflict-');
  const keys = [];
  for (const name of ['first', 'second']) {
    const file = join(root, name);
    execFileSync('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', 'fixture', '-f', file]);
    keys.push(readFileSync(file + '.pub', 'utf8').split(' ').slice(0, 2).join(' '));
  }
  const config = join(root, 'config'), known = join(root, 'known_hosts');
  writeFileSync(config, 'Host work-alias\n HostName peer.invalid\n');
  writeFileSync(known, keys.map(key => `peer.invalid ${key}`).join('\n') + '\n');
  const env = { HOME: root, TATWO2_LIVE_ROOT: root, TATWO2_SSH_CONFIG: config, TATWO2_SSH_KNOWN_HOSTS: known };
  assert.throws(() => dualPinOptions('work-alias', 22, env), /pin_conflict/);
  writeFileSync(known, `@revoked * ${keys[0]}\npeer.invalid ${keys[0]}\n`);
  assert.throws(() => dualPinOptions('work-alias', 22, env), /pin_conflict/);
});
test('REG-05 pin conflict repair retains registry and clears marker', () => {
  const s = source('Facade/DeviceFleetRoster');
  assert.match(s, /pinConflicts\?\.removeAll/);
  assert.match(s, /fleetRemember\(peer\)[\s\S]*fleetPinHost\(peer\)/);
});
test('GATE-01 REV-03 roster transport is system channel', () => {
  assert.match(source('Facade/DeviceFleetGraph'), /fleetTransport/);
  assert.match(source('Facade/DeviceFleetRoster'), /isFleetTransport/);
});
test('GATE-02 TR-02 unidentified SSH cannot inherit owner authority', () => {
  assert.match(source('Facade/OSSocketCaller'), /guard let fingerprint else \{ return false \}/);
  assert.match(source('New/DeviceFlowCards'), /可能還有連線/);
});
test('XFER-04 committed missing participants expire and can be skipped physically', () => {
  assert.match(source('Facade/PrimaryTransfer'), /skipAbsentParticipants/);
  assert.match(source('Facade/PrimaryTransfer'), /timeIntervalSince\(committedAt\)/);
});
test('REV-05 restored identity requires explicit invitation scope', () => {
  assert.doesNotMatch(source('Facade/DevicePairingHost'), /allowRePair: true/);
  assert.match(source('New/DeviceFlowCards'), /恢復.*身分/);
});
test('CUT-06 removed permission does not revoke live colleague transport', () => {
  assert.match(source('Facade/DeviceFleetRevocation'), /revokeIdentity: Bool/);
  assert.match(source('Facade/DeviceFleetRoster'), /revokeIdentity: false/);
});
test('CUT-07 endpoint sweep is TATWO-only and bounded', () => {
  assert.match(source('Facade/DeviceFleetRevocation'), /session.tatwoRelated/);
  assert.match(source('Facade/DeviceFleetRevocation'), /claimRevocationSweep/);
});
test('GATE-03 standalone installation persists upgrade digest', () => {
  assert.match(source('Facade/DeviceFleetGate'), /fleet-gate-install.json/);
});
test('GATE-04 DM-01 five permissions cannot rewrite assistant or Hands configuration', () => {
  const s = source('Facade/DeviceFleetGraph').split('static func required')[0];
  for (const method of ['push_thread','assistant_append_offline','project_proposal_decide','select_thread','remote_hands_action','hands_build'])
    assert.ok(!s.includes('"'+method+'"'), method);
});
test('DM-02 irreversible MAIN to SUB move refuses', () => {
  assert.match(source('Facade/DeviceFleetGraph'), /group.type == .sub, next.kind\(of: id\) == .owner/);
});
test('DM-03 TR-01 preview does not enroll; formal leave and approval entry', () => {
  assert.match(source('Facade/DevicePairingHost'), /previewOnly/);
  assert.match(source('DM/DeviceFlowSession'), /requestLeaveFromCard/);
  assert.match(source('New/DeviceFlowCards'), /申請離開/);
  assert.match(source('New/DeviceFlowCards'), /核准.*離開/);
});
test('DM-04 labels include group and names deduplicate fleet-wide', () => {
  // Fifth ruling: SUB primary is an explicitly designated role, never a colleague controller.
  assert.match(source('Facade/DeviceFleetRoster'), /SUB 主設備（指定）/);
  assert.match(source('Facade/DeviceFleetRoster'), /naming.devices.filter \{ \$0.id != id \}/);
});

test('W187R2: isolated real pairing, revoked owner sync, mixed pins, system channel and finite cutoff',
  { timeout: 240_000 }, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
    const root = testScratch('w187-transfer-');
    mkdirSync(join(root, 'home'));
    writeFileSync(join(root, 'owned-fixture'), 'fixture only\n');
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
        HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
        TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TEST_ROOT: root, TATWO2_W187_R2: '1',
        TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
        TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
        TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
      encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
    });
    const output = result.stdout + result.stderr;
    writeFileSync(join(root, 'w187transfer.log'), output);
    assert.equal(result.status, 0, output);
    assert.match(output, /W187R2 SUMMARY failures=0/);
    console.log(output.trim());
  });
