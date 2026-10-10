import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';

const app = 'App/Sources/Tatwo2/';
// Optional baseline mode is used only with --test-name-pattern=F2- through verify.sh.
const read = path => process.env.W185_F2_BASELINE
  ? execFileSync('git', ['show', `${process.env.W185_F2_BASELINE}:${path}`], { encoding: 'utf8' })
  : readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const tap = read(app + 'TAP/ChatGPTTap.swift');
const runner = read(app + 'Facade/ChatGPTTapTurnRunner.swift');
const engine = read(app + 'Facade/ChatLiveEngine.swift');
const mapping = read(app + 'Facade/TapProjectMap.swift');
const models = read(app + 'Chat/ChatPageModels.swift');

test('TAP route is a separate model brand after OpenAI, with unavailable placeholder and native TAP efforts', () => {
  assert.match(models, /case chatgptTap = "ChatGPT"/);
  assert.match(models, /\.openAI,\s*\.chatgptTap,/);
  assert.match(models, /if runtimeAdapter == \.chatgptTap \{ return \.chatgptTap \}/);
  assert.match(models, /var tapEfforts: \[TapEffort\]/);
  assert.match(models, /"ChatGPT \/ \\?\(title\)"/);
  const catalog = read(app + 'Chat/ChatGPTTapModelCatalog.swift');
  assert.match(catalog, /打開後選擇模型/);
  assert.match(catalog, /allowedEfforts: \[\], allowedSpeedTiers: \[\]/);
  assert.match(catalog, /guard connection == \.ready else \{ return \}/);
  assert.match(catalog, /await tap\.models\(\)/);
  assert.doesNotMatch(catalog, /UserDefaults|Data\(contentsOf:|\.write\(/);
});

test('live send dispatches prefixed TAP models before login gates or sidecar creation', () => {
  const start = engine.indexOf('let selectedModel = model ??');
  const send = engine.indexOf('return sendTap(', start);
  const sidecar = engine.indexOf('guard let sidecar = ensureSidecar', start);
  const login = engine.indexOf('EngineDisableStore.sendBlockReason', start);
  assert.ok(start > 0 && send > start && sidecar > send && login > send);
  const branch = engine.slice(engine.indexOf('private func sendTap'), engine.indexOf('private func indexTurnArtifacts'));
  assert.doesNotMatch(branch, /ensureSidecar|ClaudeSidecar\(|\.send\(text: outgoing/);
  assert.match(branch, /ChatGPTTapTurnRunner\(tap: conversationTap/);
  assert.match(branch, /\$0\.text = full/);
  assert.match(branch, /runningThreads\.remove\(threadID\)/);
  const unsentStart = branch.indexOf('case .notSubmitted(let reason):');
  const unsentEnd = branch.indexOf('default: break', unsentStart);
  assert.ok(unsentStart >= 0 && unsentEnd > unsentStart);
  const unsent = branch.slice(unsentStart, unsentEnd);
  assert.match(unsent, /outcome = \.notDelivered\(failure.message\)/);
  assert.match(unsent, /self.update\(threadID, user.id\) \{ \$0.status = Self.undeliveredRowStatus \}/);
  assert.match(branch, /delivery\?\(outcome\)/);
  const acceptance = read(app + 'Facade/ChatGPTTapAcceptance.swift');
  assert.match(acceptance, /delivery == \.notDelivered\("not submitted fixture"\)/);
  assert.match(acceptance, /model.prompt == "UI not submitted"/);
  assert.match(branch, /outcome: LiveSendDelivery = \.delivered/);
  assert.match(engine, /runner\.stop\(\)/);
  assert.doesNotMatch(runner, /ensureSidecar|Process\(|ClaudeSidecar/);
  assert.match(runner, /tap\.stop\(requestID: requestID\)/);
});

test('project map has only metadata, atomic private writes and symlink refusal', () => {
  const schema = mapping.slice(mapping.indexOf('struct TapProjectMap:'), mapping.indexOf('actor TapProjectMapStore'));
  for (const key of ['chatgpt_project_id', 'name', 'threads', 'updated_at']) assert.ok(schema.includes(key));
  assert.doesNotMatch(schema, /text|message|transcript|prompt|summary/);
  assert.match(mapping, /0o700/);
  assert.match(mapping, /O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW, 0o600/);
  assert.match(mapping, /rename\(temporary\.path, file\.path\) == 0/);
  assert.match(mapping, /info\.st_mode & S_IFMT\) == S_IFLNK/);
});

test('no general-chat fallback, and old project conversation cannot be used in inbox', () => {
  assert.match(runner, /gizmoID: destination\.map\.chatgpt_project_id/);
  assert.doesNotMatch(runner, /gizmoID: nil|temporary: true/);
  assert.match(mapping, /name: "收件匣"/);
  assert.match(mapping, /收件匣也無法使用，這句未送出/);
  assert.match(mapping, /conversationID: latest\.threads\[threadID\.uuidString\]/);
  assert.match(mapping, /candidate\.description\.contains\(project\.shortID\)/);
  assert.match(mapping, /folder\.description\.contains\(expectedID\)/);
  assert.match(mapping, /saved\.name == "TATWO · 收件匣"\s*&& folder\.description\.contains\(String\(Self\.inboxID/);
  assert.match(mapping, /conversations\(inProject: latest\.chatgpt_project_id\)/);
  assert.match(engine, /thread\.projectID == doc\.generalProjectID \? nil/);
});

test('hidden preamble and intervening-engine summary are in-memory only and bounded', () => {
  assert.match(runner, /if first \{/);
  assert.match(runner, /並帶 project_id=/);
  assert.doesNotMatch(runner, /並帶 project=/);
  assert.match(runner, /let limit = 1_500/);
  assert.match(runner, /已截斷/);
  assert.match(runner, /runtimeAdapterID == TatwoChatRuntimeAdapter\.chatgptTap\.rawValue/);
  assert.doesNotMatch(runner, /write\(to:|FileHandle|UserDefaults/);
  const acceptance = read(app + 'Facade/ChatGPTTapAcceptance.swift');
  assert.match(acceptance, /W185FakeConversationTap: ConversationTap/);
  assert.match(acceptance, /NativeStagingIsolation\.validationError/);
  assert.match(acceptance, /summary!\.count <= 1_500/);
});

// Execute the exact production handler bodies, without a browser or credentials.
const between = (source, start, end) => {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, start);
  return source.slice(a, b);
};
function projectHandler(apiSend) {
  const definitions = between(tap, 'const gizmoOf =', 'const pinOf =');
  const handler = between(tap, 'createProject: async (c) => {', 'projectDetails: async (c) => {');
  return vm.runInNewContext(`${definitions}\n({${handler}}).createProject`, { apiSend });
}

test('Pod createProject uses public first-party projects API then confirms display.description via upsert', async () => {
  const calls = [];
  const create = projectHandler(async (method, path, body) => {
    calls.push({ method, path, body: JSON.parse(JSON.stringify(body)) });
    if (path === '/backend-api/projects') {
      return { resource: { gizmo: { id: 'g-p-fixture', display: { name: body.name }, instructions: '' }, files: [] } };
    }
    return { resource: { gizmo: { id: 'g-p-fixture', display: body.display } } };
  });
  const project = await create({ name: 'TATWO · Fixture', description: 'OS project 12345678' });
  assert.equal(project.id, 'g-p-fixture');
  assert.equal(project.description, 'OS project 12345678');
  assert.deepEqual(calls[0], {
    method: 'POST', path: '/backend-api/projects',
    body: { name: 'TATWO · Fixture', instructions: '', memory_scope: 'unset' },
  });
  assert.equal(calls[1].path, '/backend-api/gizmos/snorlax/upsert');
  assert.equal(calls[1].body.gizmo_id, 'g-p-fixture');
  assert.equal(calls[1].body.display.description, 'OS project 12345678');
  assert.equal(calls[1].body.sharing[0].type, 'private');
});

test('Pod createProject rejects server error, missing project ID or unconfirmed description without a send', async () => {
  for (const response of [{ error: 'quota' }, {}, { id: 'not-project', title: 'wrong' }]) {
    const create = projectHandler(async () => response);
    await assert.rejects(create({ name: 'Fixture', description: 'id' }), /ChatGPT 建專案失敗/);
  }
  const missingDescription = projectHandler(async () => ({
    resource: { gizmo: { id: 'g-p-fixture', display: { name: 'Fixture' } } },
  }));
  await assert.rejects(missingDescription({ name: 'Fixture', description: 'id' }), /描述未確認/);
  const denied = projectHandler(async () => { throw new Error('HTTP 403'); });
  await assert.rejects(denied({ name: 'Fixture', description: 'id' }), /HTTP 403/);
  assert.match(tap, /if \(!response\.ok\) throw new Error\('HTTP ' \+ response\.status\)/);
  assert.match(tap, /try await request\("createProject"/);
  assert.match(read(app + 'TAP/TAP.swift'), /func createProject\(name: String, description: String\) async throws -> TapFolder/);
});

test('Pod project list follows cursors and exposes descriptions needed for stable ID matching', async () => {
  const definitions = between(tap, 'const gizmoOf =', 'const pinOf =');
  const handler = between(tap, 'projects: async () => {', 'createProject: async (c) => {');
  let calls = 0;
  const api = async () => (++calls === 1
    ? { cursor: 'next', items: [{ gizmo: { id: 'g-p-one', display: { name: 'fixture', description: '12345678' } } }] }
    : { cursor: null, items: [{ gizmo: { id: 'g-p-two', display: { name: 'sample', description: '87654321' } } }] });
  const projects = vm.runInNewContext(`${definitions}\n({${handler}}).projects`, {
    api, encodeURIComponent, diag: {}, keysOf: () => '',
  });
  const result = await projects();
  assert.equal(calls, 2);
  assert.equal(result.items.length, 2);
  assert.equal(result.items[1].description, '87654321');
});

test('F2-7 real TAP stop may close without terminal event; runner must complete cancellation', () => {
  const stop = between(tap, 'func stop(requestID: String)', 'private func finishStream');
  assert.match(stop, /streams\.removeValue\(forKey: stopped\)\?\.finish\(\)/);
  const ended = runner.slice(runner.indexOf('for await item in stream'), runner.indexOf('} catch {\n                // 到這裡'));
  assert.match(ended, /if stopping \{ event\(\.finished\) \}/);
  assert.match(ended, /else \{ event\(\.failed\(/);
  const fixture = read(app + 'Facade/ChatGPTTapAcceptance.swift');
  assert.match(fixture, /func stop\(requestID: String\) \{ stopped\.append\(requestID\); continuation\?\.finish\(\) \}/);
});

test('F2-8 TAP attachment admission uses secure Space reader, per-file deadline and aggregate limit', () => {
  assert.doesNotMatch(runner, /Data\(contentsOf:/);
  assert.match(runner, /ChatGPTSpaceModel\.readReceivedFile/);
  assert.match(runner, /ChatGPTSpaceModel\.readLimit\(for:/);
  assert.match(runner, /asyncAfter\(deadline: \.now\(\) \+ timeout\)/);
  assert.match(runner, /ChatGPTSpaceModel\.admit\(raw,[\s\S]*currentBytes: attachments\.reduce/);
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const reader = between(space, 'nonisolated static func readReceivedFile', 'func addData');
  assert.match(reader, /O_NOFOLLOW \| O_CLOEXEC \| O_NONBLOCK/);
  assert.match(reader, /S_IFREG[\s\S]*Int\(info\.st_size\) <= limit/);
});

test('F2-9 collaboration context is masked before truncation and visible to the user', () => {
  const summary = runner.slice(runner.indexOf('static func collaborationSummary'));
  const mask = summary.indexOf('HandsSecretLines.maskText(row.text)');
  const redact = summary.indexOf('HandsRedactor.redact(masked)');
  const truncate = summary.indexOf('safe.prefix(400)');
  assert.ok(mask >= 0 && redact > mask && truncate > redact);
  assert.match(runner, /已附上前面 .* 則其他模型的摘要（已遮敏）/);
  assert.match(runner, /if let summary = Self\.collaborationNotice\(history\) \{ notice\(summary\) \}/);
});

test('F2-10 only proven missing mappings reroute; temporary failures cannot fork a conversation', () => {
  const destination = between(mapping, 'func destination(', 'private func resolve(');
  const projectBranch = destination.slice(destination.indexOf('if let project'), destination.indexOf('// 收件匣'));
  assert.match(projectBranch, /catch ResolutionError\.missingProject/);
  assert.match(projectBranch, /catch ResolutionError\.missingConversation/);
  assert.doesNotMatch(projectBranch, /catch\s*\{/);
  assert.match(destination, /storage\.save\(map, at: project\.folder, mergeThreads: false\)/);
  assert.match(projectBranch, /map\.threads\.removeValue\(forKey: threadID\.uuidString\)/);
});

test('F2-11 send automatically refreshes stale catalog once before validating or dispatching model', () => {
  const refresh = runner.indexOf('try await ChatGPTTapModelCatalog.refreshForSend(tap: tap)');
  const validation = runner.indexOf('guard ChatGPTTapModelCatalog.isFresh');
  const send = runner.indexOf('let stream = tap.send');
  assert.ok(refresh >= 0 && validation > refresh && send > validation);
  const catalog = read(app + 'Chat/ChatGPTTapModelCatalog.swift');
  const method = between(catalog, 'static func refreshForSend(', 'static func defaultEffort');
  assert.match(method, /guard !isFresh else \{ return \}/);
  assert.match(method, /try await tap\.models\(\)/);
  assert.match(method, /重新整理失敗，這句未送出/);
  const model = read(app + 'Facade/ChatPageModel.swift');
  const admission = between(model, 'private func tapSendUnavailableReason(', 'func refreshChatGPTTapModels');
  assert.match(admission, /choice\.runtimeAdapter == \.chatgptTap, selectedRemote == nil, chatGPTTapConnection == \.ready, !ChatGPTTapModelCatalog\.isFresh/);
  assert.doesNotMatch(admission, /snapshot\.contains/);
  assert.match(model, /if tapSendUnavailableReason\(routeChoice\) != nil \{ return false \}/);
});

test('F2-13 TAP map lives in TATWO storage outside user git; no user ignore-file edits', () => {
  const file = between(mapping, 'nonisolated static func mapFile(', 'struct TapProjectContext');
  assert.match(file, /TATWO2_LIVE_ROOT/);
  assert.match(file, /applicationSupportDirectory/);
  assert.match(file, /SHA256\.hash/);
  assert.match(file, /tap-maps\//);
  assert.doesNotMatch(file, /folder\.appendingPathComponent\("\.tatwo|\.gitignore|\/exclude/);
});
