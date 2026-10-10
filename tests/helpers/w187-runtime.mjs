import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './test-scratch.mjs';

export function runIsolated(selftest, flags = {}, { shortSocketPaths = false } = {}) {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-runtime-', shortSocketPaths ? { base: '/private/tmp' } : {});
  for (const folder of ['home','tmp','engines/codex','engines/claude','os','docs','artifacts']) mkdirSync(join(root,folder),{recursive:true});
  writeFileSync(join(root,"owned-fixture"), "synthetic only\n");
  writeFileSync(join(root,"engines/codex/config.toml"), "[features]\nplugins=false\nplugin_sharing=false\n");
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, ["memory-launch","session-switch","admission-once","r11-admission"].includes(flags.TATWO2_W187_R8) ? ["-tatwo2.sidecarPath.codex", join(process.cwd(),"Engines/codex-sidecar/sidecar.mjs")] : [], {
    env: { PATH: process.env.PATH, TMPDIR: join(root,"tmp"), TATWO2_RUNTIME_BIN: "/Applications/TATWO OS.app/Contents/Resources/runtime/bin",
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: join(root,'home'),
      TATWO2_ENGINES_ROOT: join(root,'engines'), CODEX_HOME: join(root,'engines/codex'),
      TATWO2_CODEX_SOURCE_HOME: join(root,'engines/codex'), CLAUDE_CONFIG_DIR: join(root,'engines/claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR: join(root,'engines/claude'),
      TATWO2_OS_SOCKET: join(root,'o.sock'), TATWO2_BROWSER_SOCKET: join(root,'b.sock'),
      TATWO2_OS_ROOT: join(root,'os'), TATWO2_DOCS_ROOT: join(root,'docs'),
      TATWO2_OS_UPSTREAM_PATH: join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH: join(root,'os/skillet.md'),
      TATWO2_LIVE_ROOT: join(root,'live'), TATWO2_AUTHORIZED_KEYS: join(root,'authorized_keys'),
      TATWO2_SSH_KNOWN_HOSTS: join(root,'known_hosts'), TATWO2_SSH_KEY_PATH: join(root,'fixture-key'),
      TATWO2_SSH_HOST_KEY_PUB: join(root,'fixture-host.pub'), TATWO2_SELFTEST_ARTIFACTS: join(root,'artifacts'),
      TATWO2_W187_TEST_ROOT: root, TATWO2_W187_NODE: process.execPath,
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', TATWO2_SELFTEST: selftest, ...flags },
    encoding:'utf8', timeout:220_000, maxBuffer:8*1024*1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output + `\nsignal=${result.signal} error=${result.error?.message ?? ""}`);
  assert.doesNotMatch(output,/SUMMARY.*failures=[1-9]/);
  return {root, output};
}
