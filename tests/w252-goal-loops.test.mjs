import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {testScratch} from './helpers/test-scratch.mjs';

const checkout = fileURLToPath(new URL('..', import.meta.url));
const read = file => fs.readFileSync(path.join(checkout, file), 'utf8');
const src = 'App/Sources/Tatwo2/';

test('W252 goal_update schema permits progress-only updates and documents steps', () => {
  const line = read('Engines/os-mcp/server.mjs').split('\n').find(line => line.trim().startsWith("['goal_update',"));
  const [name, description, fields, required] = vm.runInNewContext(line.trim().slice(0, -1));
  assert.equal(name, 'goal_update');
  assert.ok(!required.includes('status'));
  for (const key of ['progress', 'etaMinutes']) assert.equal(fields[key].type, 'number');
  for (const key of ['queue', 'doneSteps']) {
    assert.equal(fields[key].type, 'array'); assert.equal(fields[key].items.type, 'string');
  }
  for (const key of ['branch', 'device']) assert.equal(fields[key].type, 'string');
  assert.match(description, /在跑時更新 progress 與 etaMinutes，步驟做完移到 doneSteps/);
  const bridge = read(src + 'Facade/OSAgentBridge.swift');
  assert.match(bridge, /status != nil \|\| hasDetails else \{ throw BridgeError.invalidParams \}/);
  assert.match(bridge, /requested != roomGoal\.id \{ throw ThreadGoalRules\.Failure\.subOnlyOwnGoal \}/);
  assert.match(bridge, /ownGoalID: roomGoal\?\.id/);
});

test('W252 card preserves interactions and uses existing visual tokens for new rows', () => {
  const card = read(src + 'Chat/ThreadGoalCard.swift');
  assert.doesNotMatch(card, /let groups:|showDone|sectionTitle\("(?:進行中|待做|待驗收|暫停|已完成)/);
  assert.match(card, /ForEach\(Self\.ordered\(main\)\)/);
  assert.match(card, /@State private var openGoals: Set<Int> = \[\]/);
  assert.match(card, /frame\(width: 64, height: 3\)/);
  assert.match(card, /Capsule\(\)\.fill\(LiquidGlassTokens\.brandAccent\)/);
  assert.match(card, /opacity\(child\.status == \.done \? LiquidGlassTokens\.routePulseOpacity : 1\)/);
  const rows = card.slice(card.indexOf('private func title('), card.indexOf('private func proposalRow('));
  assert.doesNotMatch(rows, /\.font\(\.system\(size: \d|\.padding\([^\n]*\d|HStack\(spacing: \d|VStack\([^\n]*spacing: \d/);
  assert.doesNotMatch(card, /Color\.(?:green|orange|red|black|white)|Color\(red:/);
  for (const action of ['設為進行中', '標為完成', '暫停', '改文字', '刪除這一條', '加入主線', '不要']) assert.ok(card.includes(action), action);
  assert.match(card, /if let room = linkedRoom\(child\) \{\s*roomView\(\[room\], false\)/);
  assert.match(read(src + 'SelfTest.swift'), /"w252goalloops": \("W252GOALLOOPS", \{ try await W252GoalLoopsAcceptance\.run\(\) \}\)/);
});

test('W252 native card presses, progress, dimmed completed rows, legacy data and four theme screenshots', {timeout: 180000}, () => {
  const binary = process.env.TATWO2_TEST_BINARY;
  assert.ok(binary && fs.existsSync(binary), 'TATWO2_TEST_BINARY is required');
  const root = fs.realpathSync(testScratch('w252-goal-native-'));
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) fs.mkdirSync(path.join(root, dir), {recursive: true});
  const env = {...process.env, HOME: `${root}/home`, CFFIXED_USER_HOME: `${root}/home`, TATWO_STAGING_SCRATCH_HOME: `${root}/home`, TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: `${root}/live`, TATWO2_ENGINES_ROOT: `${root}/engines`, CODEX_HOME: `${root}/engines/codex`, TATWO2_CODEX_SOURCE_HOME: `${root}/engines/codex`,
    CLAUDE_CONFIG_DIR: `${root}/engines/claude`, CLAUDE_SECURESTORAGE_CONFIG_DIR: `${root}/engines/claude`, TATWO2_OS_SOCKET: `${root}/o.sock`, TATWO2_BROWSER_SOCKET: `${root}/b.sock`,
    TATWO2_OS_ROOT: `${root}/os`, TATWO2_DOCS_ROOT: `${root}/docs`, TATWO2_OS_UPSTREAM_PATH: `${root}/os/os-upstream.md`, TATWO2_SKILLET_PATH: `${root}/os/skillet.md`,
    TATWO2_SELFTEST: 'w252goalloops', TATWO2_SELFTEST_ARTIFACTS: `${root}/artifacts`};
  const run = spawnSync(binary, [], {env, encoding: 'utf8', timeout: 170000, maxBuffer: 8 * 1024 * 1024});
  const output = (run.stdout ?? '') + (run.stderr ?? ''); fs.writeFileSync(`${root}/result.log`, output);
  console.log(`W252 native evidence: ${root}`);
  assert.equal(run.status, 0, output || String(run.error));
  assert.match(output, /W252GOALLOOPS SUMMARY failures=0 passed=[1-9]\d*/);
  assert.doesNotMatch(output, /\bSKIP\b/);
  for (const theme of ['fable5', 'aurora']) for (const scheme of ['light', 'dark']) {
    const name = theme + '-' + scheme;
    for (const check of ['default only mainlines', 'active review queue paused done order', 'active progress and remaining time', 'completed row visibly dimmer', 'thin progress bar drawn at 65 percent', 'readable appearance', 'device branch and completed queued steps']) {
      assert.ok(output.includes(`PASS ${name} ${check}`), `${name} ${check}`);
    }
    const image = path.join(root, 'artifacts', `w252-${name}.png`);
    assert.ok(fs.existsSync(image), image);
    assert.equal(fs.readFileSync(image).subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  }
  for (const check of ['legacy mainline renders and expands', 'legacy loop renders without new fields', 'engine updates details without status', 'goal_list returns all shared fields and ISO8601 dates']) {
    assert.ok(output.includes(`PASS ${check}`), check);
  }
});
