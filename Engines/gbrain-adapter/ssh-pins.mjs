import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Read-only caller policy shared by GBrain and the repository's SSH scripts.
export function dualPinOptions(target, port = 22, environment = process.env) {
  const host = target.slice(target.lastIndexOf('@') + 1);
  if (!host || host.startsWith('-') || /[\s\0]/.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid_ssh_target');
  const live = environment.TATWO2_LIVE_ROOT || path.join(environment.HOME || os.homedir(), 'Library/Application Support/tatwo2/live');
  const files = [environment.TATWO2_SSH_KNOWN_HOSTS || environment.TATWO2_KNOWN_HOSTS || path.join(environment.HOME || os.homedir(), '.ssh/known_hosts'), path.join(live, 'fleet-known-hosts')];
  const address = port === 22 ? host : `[${host}]:${port}`;
  const keys = new Set(), revoked = new Set();
  let literalPin = false;
  const collectPins = lookup => {
    for (const file of files) {
      if (/[\r\n\0]/.test(file)) throw new Error('invalid_pin_path');
      let text;
      try { text = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
      if (Buffer.byteLength(text) > 4 * 1024 * 1024) throw new Error('pin_file_too_large');
      for (const line of text.split('\n')) {
        const f = line.trim().split(/\s+/);
        if (f[0] === '@revoked' && f.length >= 4) revoked.add(`${f[2]} ${f[3]}`);
      }
      const found = spawnSync('/usr/bin/ssh-keygen', ['-F', lookup, '-f', file], { encoding: 'utf8', timeout: 5000, maxBuffer: 4 * 1024 * 1024 });
      if (found.error || ![0, 1].includes(found.status)) throw new Error('pin_lookup_failed');
      for (const line of found.stdout.split('\n')) {
        if (!line.trim() || line.startsWith('#')) continue;
        const f = line.trim().split(/\s+/);
        if (f[0] === '@cert-authority' || f[0] === '@revoked') continue; // Actual pinned-key revocation is checked below.
        const algorithm = f[0].startsWith('@') ? f[2] : f[1];
        if (algorithm !== 'ssh-ed25519') continue;
        if (f.length < 3 || f[0].startsWith('@')) throw new Error('pin_conflict');
        keys.add(`${f[1]} ${f[2]}`);
      }
    }
    if (keys.size > 1 || [...keys].some(key => revoked.has(key))) throw new Error('pin_conflict');
  };
  try {
    collectPins(address);
    literalPin = keys.size === 1;
    if (!literalPin) {
      // A config alias may resolve to a hostname already trusted by OpenSSH.
      // Leave HostKeyAlias unset in this case; strict verification still uses both stores.
      const config = environment.TATWO2_SSH_CONFIG || path.join(environment.HOME || os.homedir(), '.ssh/config');
      if (!fs.existsSync(config)) throw new Error('paired_host_key_not_found');
      const resolved = spawnSync('/usr/bin/ssh', ['-F', config, '-G', ...(port === 22 ? [] : ['-p', String(port)]), '--', host], { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024 });
      const hostname = resolved.stdout?.match(/^hostname (.+)$/m)?.[1];
      const alias = resolved.stdout?.match(/^hostkeyalias (.+)$/m)?.[1];
      const resolvedPort = Number(resolved.stdout?.match(/^port ([0-9]+)$/m)?.[1] || port);
      if (resolved.error || resolved.status !== 0 || !hostname || (hostname === host && !alias)) throw new Error('paired_host_key_not_found');
      const lookup = alias || (resolvedPort === 22 ? hostname : `[${hostname}]:${resolvedPort}`);
      collectPins(lookup);
    }
  } catch (e) {
    // A fixed rejection marker is safe for callers' existing diagnostic logs.
    process.stderr.write(e.message === 'pin_conflict' ? 'REG-05 pin_rejected: pin_conflict\n' : 'REG-05 pin_rejected: pin_unavailable\n');
    throw e;
  }
  const quote = value => '"' + value.replaceAll('\\', '\\\\').replaceAll('"', '\\"') + '"';
  return ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', `UserKnownHostsFile=${files.map(quote).join(' ')}`,
    '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'KnownHostsCommand=none', '-o', 'VerifyHostKeyDNS=no', '-o', 'UpdateHostKeys=no',
    ...(literalPin ? ['-o', `HostKeyAlias=${address}`] : []), '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'CheckHostIP=no', '-o', 'ControlMaster=no', '-o', 'ControlPath=none'];
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(dualPinOptions(process.argv[2] || '', Number(process.argv[3] || 22)).join('\n') + '\n'); }
  catch { process.exitCode = 1; }
}
