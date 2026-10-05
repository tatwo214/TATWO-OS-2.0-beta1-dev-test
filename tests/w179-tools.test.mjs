import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');
const swift = 'App/Sources/Tatwo2/';
const parent = process.env.TATWO2_W179_TEST_ROOT || path.resolve(repo, '../../tmp/w179c-tools');
function scratch(prefix) {
  fs.mkdirSync(parent, { recursive: true });
  return fs.realpathSync(fs.mkdtempSync(path.join(parent, prefix)));
}

test('W179 tool declarations, trust boundaries, read-only sources and synchronized guidance', () => {
  const server = read('Engines/os-mcp/server.mjs');
  for (const name of ['os_status', 'goal_index']) {
    assert.equal([...server.matchAll(new RegExp(`^  \\['${name}',.*\\],$`, 'gm'))].length, 1,
      `${name}: one tuple per line for plugin liveness scanner`);
  }
  const bridge = read(swift + 'Facade/OSAgentBridge.swift');
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    const body = bridge.match(new RegExp(`static let ${list}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1];
    assert.ok(body !== undefined, list);
    assert.doesNotMatch(body, /"os_status"|"goal_index"/, list);
    // W182 R5：補回助理那條只在 SSH（已配對設備）清單。
    assert.equal(body.includes('"assistant_append_offline"'), list === 'sshForwardMethods', list);
  }
  const status = bridge.slice(bridge.indexOf('case "os_status":'), bridge.indexOf('case "list_devices":'));
  assert.match(status, /backgroundJobSnapshot\(includeLastLine: false\)/);
  assert.match(status, /IslandWorkProvider\.project/);
  assert.match(status, /limit: nil/);
  assert.match(status, /model\.devices/);
  assert.doesNotMatch(status, /deviceRecordsForBridge|\.resolve\(|\.update\(|\.list\(threadID:/);
  const goals = bridge.slice(bridge.indexOf('case "goal_index":'), bridge.indexOf('case "os_status":'));
  assert.match(goals, /ThreadGoalStore\.shared\.list/);
  assert.match(goals, /ThreadGoalRules\.progress\(list\)/);
  assert.match(goals, /CFBooleanGetTypeID/);
  assert.doesNotMatch(goals, /jsonObject\(list|\.update\(|\.save\(/);
  assert.equal(read('docs/os-upstream.md'), read(swift + 'Resources/os-upstream.md'));
  assert.match(read('docs/os-upstream.md'), /全域狀態或目標.*`os_status`、`goal_index`/);
  assert.match(read('docs/os-mcp-tools.md'), /52 個工具/);   // W180 E1：加了三個記憶工具；E3b 兩個分類工具；W183 R3 兩個手腳設定工具
});

test('W179 Island classification and room failure wording remain identical to w179/base', () => {
  const name = swift + 'Facade/IslandWorkProvider.swift';
  const base = spawnSync('git', ['show', `w179/base:${name}`], { cwd: repo, encoding: 'utf8' });
  assert.equal(base.status, 0, base.stderr);
  const classification = source => {
    const block = source.match(/            let since = thread\.lastOutputAt[\s\S]*?(?=        }\n        let dates)/)?.[0];
    assert.ok(block, 'thread classification, inclusion, hint and projection block exists');
    return block;
  };
  assert.equal(classification(read(name)), classification(base.stdout));
  assert.match(classification(read(name)), /"房間失敗"/);
});

test('W179 goal_index and os_status always read the local engine and identify the local device', () => {
  const model = read(swift + 'Facade/ChatPageModel.swift');
  assert.match(model, /var localLiveForBridge: ChatLiveEngine\? \{ localLive \}/);
  const bridge = read(swift + 'Facade/OSAgentBridge.swift');
  const goals = bridge.slice(bridge.indexOf('case "goal_index":'), bridge.indexOf('case "os_status":'));
  const status = bridge.slice(bridge.indexOf('case "os_status":'), bridge.indexOf('case "list_devices":'));
  for (const body of [goals, status]) {
    assert.match(body, /model\??\.localLiveForBridge/);
    assert.doesNotMatch(body, /model\??\.live\b/);
  }
  assert.match(goals, /"device": "local"/);
  assert.match(status, /Self\.statusMetadata\(doc: input\.doc/);
  const metadata = bridge.slice(bridge.indexOf('static func statusMetadata('), bridge.indexOf('static func cliSendReceipt('));
  assert.match(metadata, /result\["device"\] = "local"/);
});

test('W179 real MCP transport: valid metadata injection and fail-closed arguments, bound and unbound', { timeout: 30_000 }, () => {
  const root = scratch('mcp-');
  const run = spawnSync(process.execPath, [path.join(repo, 'Engines/os-mcp/caller-test.mjs')], {
    env: { ...process.env, TATWO2_CALLER_TRANSPORT_ROOT: root },
    encoding: 'utf8', timeout: 25_000,
  });
  fs.writeFileSync(path.join(root, 'caller.log'), run.stdout + run.stderr);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /bound all_tools=54/);   // W198（.056）兩個派工工具； W180 E1：加了三個記憶工具；E3b 兩個分類工具；W183 R3 兩個手腳設定工具
  assert.match(run.stdout, /unbound all_tools=54/);
});

test('W179 real Swift bridge: isolated goal_index and os_status metadata-only acceptance', { timeout: 120_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY || path.resolve(repo, '../../build-cache/c-tools/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'Set TATWO2_TEST_BINARY to current build; never skip bridge acceptance');
  const root = scratch('os-');
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e', 'entry', 'docs']) fs.mkdirSync(at(name));
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
    HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'),
    TATWO2_LIVE_ROOT: at('l'), TATWO2_ENGINES_ROOT: at('e'),
    CODEX_HOME: at('e/codex'), TATWO2_CODEX_SOURCE_HOME: at('e/codex'),
    CLAUDE_CONFIG_DIR: at('e/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('e/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO_OS_ROOT: at('entry'), TATWO2_OS_ROOT: at('entry'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('docs/os-upstream.md'), TATWO2_SKILLET_PATH: at('entry/skillet.md'),
    TATWO2_SELFTEST: 'w179tools',
  };
  assert.ok(Buffer.byteLength(env.TATWO2_OS_SOCKET) < 104, 'fixture socket path too long');
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 100_000, maxBuffer: 4 * 1024 * 1024 });
  const output = run.stdout + run.stderr;
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(run.status, 0, output);
  assert.match(output, /W179TOOLS ALL PASS/);
  assert.doesNotMatch(output, /W179TOOLS FAIL/);
  for (const label of [
    'goal_index default excludes done; true includes archived and done-only threads',
    'goal_index identity and full mainline progress',
    'global running threads not truncated',
    'bridge reads leave persisted files byte-identical',
    'bridge reads leave document and selection unchanged',
    'both tools identify local device',
    'Island ignores idle stalled/error history and retains room failure wording',
    'bridge output excludes message, brief, goal source/evidence and command/log',
    'approval takes precedence over running',
    'CLI and device allowlisted projection',
    'bridge lists active and queued Island titles without resolving requests',
    'fallback-hosted pending request remains visible',
    'os_status rejects ssh staging=true', 'goal_index rejects ssh staging=true',
    'os_status rejects other(?) staging=true', 'goal_index rejects other(?) staging=true',
  ]) assert.ok(output.includes('W179TOOLS PASS ' + label), label);
});
