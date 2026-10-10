import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W221c unmanaged keys survive update, pairing, revocation and removal; restricted duplicates fail closed', { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY);
  const root = testScratch('w221c-keys-');
  mkdirSync(join(root, 'home'));
  writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO2_SELFTEST: 'w187fleet', TATWO2_W221C: 'keys', TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root, 'test.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W221C SUMMARY checks=19 failures=0/);
  console.log(output.trim());
});


test('production RPC authorization accepts CRLF without treating Unicode separators as SSH lines', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/DeviceDispatch.swift', 'utf8');
  const predicate = source.match(/authorized\.(?:split|components)\([\s\S]+?\)\.contains\(where: \{ line in[\s\S]+?\}\)/)?.[0];
  assert.ok(predicate, 'production authorization predicate required');
  const root = testScratch('w221c-lines-');
  const probe = join(root, 'probe.swift');
  writeFileSync(probe, `import Foundation
let components = "ssh-ed25519 peer".split(whereSeparator: \\.isWhitespace)
let fixtures = ["ssh-ed25519 owner\\r\\nssh-ed25519 peer\\r\\n", "ssh-ed25519 owner\\u{2028}ssh-ed25519 peer"]
for authorized in fixtures { print(${predicate}) }
`);
  const result = spawnSync('/usr/bin/swift', [probe], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(result.stdout, 'true\nfalse\n');
});


test('production authorized reader retains BOM, CRLF, blank rows and missing final newline byte for byte', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/DeviceRegistry.swift', 'utf8');
  const start = source.indexOf('private static func readAuthorizedLines');
  assert.ok(start >= 0);
  const open = source.indexOf('{', start); let depth = 1, end = open + 1;
  while (depth && end < source.length) { const c = source[end++]; if (c === '{') depth++; if (c === '}') depth--; }
  assert.equal(depth, 0);
  const root = testScratch('w221c-reader-'), probe = join(root, 'reader.swift');
  writeFileSync(probe, `import Foundation
  enum Probe {
    enum RegistryError: Error { case invalidPublicKey, authorizedKeysNotUTF8 }
    ${source.slice(start, end)}
    static func run(_ root: String) throws {
      for (i, bytes) in [Data([0xef, 0xbb, 0xbf]) + Data("# user row\\r\\n\\r\\n".utf8),
                         Data("# user row\\n# final row without delimiter".utf8)].enumerated() {
        let url = URL(fileURLWithPath: root).appendingPathComponent("fixture-\\(i)")
        try bytes.write(to: url)
        guard try Data(readAuthorizedLines(at: url).joined().utf8) == bytes else { fatalError("user bytes changed") }
      }
      print("READER EXACT BYTES PASS")
    }
  }
  try Probe.run(CommandLine.arguments[1])
  `.replaceAll('\\\\', '\\'));
  const run = spawnSync('/usr/bin/swift', [probe, root], { encoding: 'utf8', timeout: 30_000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /READER EXACT BYTES PASS/);
});
