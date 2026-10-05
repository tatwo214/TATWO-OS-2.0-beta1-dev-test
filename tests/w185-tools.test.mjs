import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => {
  if (!process.env.W185_F2_BASELINE) return fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2', name), 'utf8');
  const result = spawnSync('git', ['show', `${process.env.W185_F2_BASELINE}:App/Sources/Tatwo2/${name}`], { cwd: repo, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};
const tools = read('Facade/HandsTools.swift');
const service = read('Facade/HandsService.swift');
const skillet = read('Facade/HandsSkillet.swift');
const controller = read('New/ComputerUseController.swift');
const external = read('New/ComputerUseExternalSession.swift');
const policy = read('New/ComputerUseExternalPolicy.swift');
const journal = read('Facade/HandsChatGPTRoom.swift');
const section = (source, first, next) => {
  const a = source.indexOf(first); assert.ok(a >= 0, first);
  const b = next ? source.indexOf(next, a + first.length) : source.length;
  return source.slice(a, b < 0 ? source.length : b);
};

test('W185 catalog is explicit, L1 readonly skillet, L2 CU, no approval/start/batch tool', () => {
  const specs = new Map([...tools.matchAll(/HandsToolSpec\(id: "([^"]+)", level: (\d)/g)].map(m => [m[1], +m[2]]));
  for (const name of ['skillet_list', 'skillet_read']) {
    assert.equal(specs.get(name), 1);
    assert.match(section(tools, `HandsToolSpec(id: "${name}"`, '\n        HandsToolSpec('), /readOnly: true/);
  }
  for (const name of ['computer_request', 'computer_status', 'computer_observe', 'computer_action', 'computer_stop']) assert.equal(specs.get(name), 2);
  assert.equal(specs.has('computer_start'), false);
  assert.equal(specs.has('computer_batch'), false);
  assert.equal(specs.has('computer_approve'), false);
  const request = section(tools, 'HandsToolSpec(id: "computer_request"', 'HandsToolSpec(id: "computer_status"');
  assert.match(request, /minimum: 1, maximum: 15/);
  assert.match(request, /host.*Island/);
});

test('skillet only dispatched index, anchored openat, no symlinks/hardlinks/nonregular/secret/oversize/private discovery', () => {
  assert.match(skillet, /TATWO2_SKILLET_PATH/);
  for (const needle of ['openat(', 'O_NOFOLLOW', 'O_NONBLOCK', 'info.st_nlink == 1', 'info.st_mode & S_IFMT == S_IFREG',
    'data.count <= limit', '64 * 1024', 'HandsSecretFiles.isSecret', 'skills.first(where:', 'skillet_not_listed',
    'path.hasPrefix("skills/")', 'contains("..")', 'path.hasSuffix("/SKILL.md")']) assert.ok(skillet.includes(needle), needle);
  assert.doesNotMatch(skillet, /contentsOfDirectory|\.codex\/skills|\.claude\/skills|Process\(/);
  assert.ok(skillet.indexOf('HandsSecretLines.maskText(content)') >= 0);
  assert.match(skillet, /"description": redact\(\$0\.description, service: service\)/);
  assert.match(skillet, /TatwoMemoryStore\.containsSecret\(\$0\)/);
  assert.match(skillet, /if let activeSection, !line\.hasPrefix\("## "\)/);
});

test('CU never uses internal auto-allow/cache/self target; host Island click required and lease <=15m', () => {
  const start = section(controller, 'private func start(caller:', '/// No internal full-access');
  assert.match(start, /external == nil \? consentPolicyProvider\(caller\) : \.askOncePerSession/);
  assert.match(start, /if let external \{/);
  assert.match(start, /IslandNotice\.shared\.hostAvailable/);
  assert.match(start, /decision == \.allow/);
  assert.match(start, /fullTextRequired: true/);
  assert.match(start, /Double\(\$0\.minutes \* 60\)/);
  const externalStart = section(controller, 'func startExternal(', 'func externalGrant(');
  assert.match(externalStart, /granted == nil, pendingConsent == nil, consentCache == nil/);
  assert.match(external, /allowSelfTarget: false/);
  assert.match(external, /Only the user at the host machine/);
  assert.doesNotMatch(external, /\.resolve\(\.allow/);
});

test('CU restrictions are layered, native preflight before background and foreground input, capture gates untouched', () => {
  for (const id of ['com.apple.terminal', 'com.googlecode.iterm2', 'dev.warp.warp-stable', 'com.mitchellh.ghostty',
    'com.binance.desktop', 'com.ibkr.tws', 'com.apple.safari']) assert.ok(policy.includes(`"${id}"`), id);
  assert.match(policy, /ComputerUseTarget\.deniedIdentifiers\.union/);
  assert.match(policy, /allowSelf: false/);
  assert.match(policy, /focusOwnerAllowed\(owner: owner, target: pid\)/);
  assert.match(policy, /owner == target/);
  assert.match(policy, /role != "AXWebArea"/);
  assert.match(policy, /documentAllowed\(state.documentURL, runtime: runtime\)/);
  assert.match(policy, /requireNonSecure/);
  assert.match(policy, /!state\.truncated/);
  assert.match(policy, /ComputerUseNative\.isSecure/);
  assert.equal((controller.match(/ComputerUseExternalPolicy\.preflight\(pid: grant\.pid/g) ?? []).length, 2);
  assert.match(controller, /includeTree: includeTree \|\| externalAI/);
  assert.match(controller, /if externalAI \{ try ComputerUseExternalPolicy\.validate\(state\) \}/);
  assert.match(controller, /disclosure\[observedID\]\?\.usable == true/);
  assert.match(controller, /CGPreflightScreenCaptureAccess\(\)/);
  assert.match(external, /BrowserSensitivePageGate\.isActive/);
  assert.match(external, /IslandNotice\.shared\.pendingRequestIDs\.isEmpty/);
});

test('CU hardening uses trusted app categories, protected paths, paste and per-dispatch approval gates', () => {
  for (const needle of ['LSApplicationCategoryType', 'allowedCategories', 'computer_external_app_category_denied',
    'com.apple.finder', 'wezterm', 'jetbrains', 'okx', '證券', 'runtime.paths.root.path', 'runtime.entryRoot',
    'engines.enginesRoot.path', 'TATWO2_CODEX_SOURCE_HOME', 'destinationOfSymbolicLink', 'requireNoPasteCommand',
    'AXMenuItemCmdVirtualKey', 'checkPendingApproval', 'ready.wait(timeout: .now() + 0.25)', 'NSApp?.modalWindow']) {
    assert.ok(policy.includes(needle), needle);
  }
  assert.match(external, /backend.application\(app\)/);
  assert.match(external, /reasonLine\(reason\)/);
  assert.match(external, /validateRequest\(request\)/);
  assert.match(controller, /application.categoryLabel/);
  assert.match(controller, /externalAI: externalAI/);
  assert.match(controller, /let valueLimit = externalAI \? 4096 : 300/);
  assert.match(controller, /textChunks\(text, maxUTF16: 300\)/);
  assert.match(controller, /reply\["sent_characters"\] = text.count/);
  const background = section(controller, 'static func backgroundInput(', '/// An enabled menu item');
  assert.match(background, /externalCheck\(focus\)/);
  assert.match(background, /externalCheck\(item\)/);
  assert.match(background, /externalCheck\(node\)/);
  const pointer = read('New/ComputerUsePointer.swift');
  assert.match(pointer, /if externalAI \{ try ComputerUseExternalPolicy.requireBackgroundPointer/);
  assert.match(pointer, /try pointAllowed\(point\)/);
  assert.match(read('Facade/HandsW185Acceptance.swift'), /HandsW185CUAcceptance.run/);
  const acceptance = read('Facade/HandsW185CUAcceptance.swift');
  for (const name of ['category_missing', 'explicit_app_denial_', 'protected_document_observe_', 'paste_key_',
    'paste_menu_ax_', 'hid_only_pointer_refused', 'pending_approval_dispatch_refused',
    'reason_invisible_controls_removed', 'type_500_chunked_complete_count', 'stop_between_chunks_fences_input']) {
    assert.ok(acceptance.includes(name), name);
  }
});

test('expiry, local stop, revocation and cross-grant isolation use existing native epoch gate', () => {
  assert.match(external, /enum State: String \{ case pending, allowed, denied, expired \}/);
  for (const needle of ['current.grantID == grant', 'current.service === service', 'session.stop(ifCurrent:',
    'backend.session.validate(native)', 'app.isTerminated', 'externalGrant(owner:', 'admissionProblem(',
    'Timer.scheduledTimer(withTimeInterval: 0.25', 'self.current?.state = .expired']) assert.ok(external.includes(needle), needle);
  const revoke = section(external, 'func revoke(grants:', 'func stopCurrent(');
  assert.match(revoke, /current\.1\.stop\(ifCurrent: current\.2\)/);
  assert.doesNotMatch(revoke, /DispatchQueue|Task|await/);
  assert.match(service, /HandsComputerRevocations\.shared\.revoke\(grants: Set\(ids\)\)/);
  assert.match(service, /if new.level < 2 \|\| !new.enabled \{ HandsComputerRevocations.shared.stopCurrent\(\) \}/);
  assert.match(read('New/ComputerUseConsentPrompt.swift'), /ChatGPT 正在操作/);
  assert.match(read('New/ComputerUseConsentPrompt.swift'), /Button\("停止", role: \.destructive\)/);
});

test('C3 project ID validation, no guessing/auto-create, workspace consistency, journal not dialogue', () => {
  for (const [a, b] of [['memory_inbox_save', 'memory_inbox_list'], ['propose_goal', 'write_report'], ['write_report', 'computer_request']]) {
    const spec = section(tools, `HandsToolSpec(id: "${a}"`, `HandsToolSpec(id: "${b}"`);
    assert.match(spec, /"project_id": optionalProjectID/);
  }
  assert.match(tools, /In a ChatGPT project created by TATWO, pass that project's ID/);
  assert.match(journal, /"choices": projects\.map\(\\\.name\)/);
  assert.match(journal, /project_workspace_mismatch/);
  assert.match(journal, /jobs\.job\(jobID, grant: grant\.grantID\)/);
  assert.match(journal, /ChatGPT · 未分類/);
  const row = section(journal, 'struct HandsRoomCall:', 'final class HandsRoomJournal');
  assert.doesNotMatch(row, /let (content|arguments|prompt|conversation|image|text|result)/);
  assert.match(service, /let target = rootThread\(projectID: landing\.projectID\)/);
  assert.match(service, /journal\(tool: name, summary: summary/);
  assert.match(service, /!name.hasPrefix\("computer_"\)/);
  assert.match(tools, /text\.utf8\.count\) bytes/);
});

test('image is MCP image content, not clipped JSON/base64 persisted to ledger; external errors are codes only', () => {
  assert.match(tools, /removeValue\(forKey: "imageBase64"\)/);
  assert.match(tools, /output\.image = \["type": "image", "data": image/);
  assert.match(service, /if let image, !isError \{ content.append\(image\) \}/);
  assert.match(external, /Native refusal diagnostics can contain window titles/);
  assert.match(external, /code\.prefix \{/);
});

test('audit is durable before execution, one bounded file per call, no dropped or truncated history', () => {
  assert.match(journal, /row.id.uuidString \+ ".json"/);
  assert.doesNotMatch(journal, /rows.suffix|removeItem|unlink|removeFirst/);
  assert.match(service, /let auditReady = journal\(tool: name, summary: "呼叫中"/);
  assert.match(service, /if !auditReady, name != "computer_stop"/);
  assert.match(service, /nothing was done; the host must restore audit storage/);
  assert.match(controller, /authority.externalAdmission\(\)/);
  assert.match(external, /guard record\(value, state: "allowed"/);
  assert.match(controller, /let target, !target\.isTerminated/);
});

test('Coder row opens project journal and existing transcript, map only when valid; selftest registered', () => {
  assert.match(read('Chat/ChatPage+Sidebar.swift'), /ChatGPTRoomRow\(projectID: project\.id, workdir: project\.workdir\)/);
  const row = read('Chat/ChatGPTRoomRow.swift');
  for (const needle of ['ChatGPT 房', 'ChatGPT 專案：', 'DisclosureGroup', 'workspaceID', '操作畫面：', 'rootThread(projectID: projectID)',
    'Task.detached', 'roomJournal.rows(projectID: projectID)']) assert.ok(row.includes(needle), needle);
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w185tools"[\s\S]{0,200}HandsW185Acceptance\.run\(\)/);
});

test('compiled w185tools executable selftest (isolated fake UI, real Hands/auth/journal/epoch)', {
  skip: !process.env.TATWO2_TEST_BINARY,
  timeout: 180_000,
}, () => {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'w185t-'));
  let fixtureNodeDirectory;
  try {
    let fixtureNode = process.env.TATWO2_SELFTEST_NODE;
    if (!fixtureNode && !['/opt/homebrew/bin/node', '/usr/local/bin/node'].some(fs.existsSync)) {
      fixtureNodeDirectory = fs.mkdtempSync('/private/tmp/w185-node-');
      fixtureNode = path.join(fixtureNodeDirectory, 'node');
      fs.copyFileSync(process.execPath, fixtureNode);
      fs.chmodSync(fixtureNode, 0o700);
    }
    const home = path.join(base, 'home'), live = path.join(base, 'live'), engines = path.join(base, 'engines'), entry = path.join(base, 'os');
    for (const dir of [home, live, entry, path.join(engines, 'codex'), path.join(engines, 'claude')]) fs.mkdirSync(dir, { recursive: true });
    const env = { ...process.env,
      HOME: home, CFFIXED_USER_HOME: home, TATWO_STAGING_ROOT: base, TATWO_STAGING_SCRATCH_HOME: home,
      TATWO2_LIVE_ROOT: live, TATWO2_ENGINES_ROOT: engines,
      CODEX_HOME: path.join(engines, 'codex'), TATWO2_CODEX_SOURCE_HOME: path.join(engines, 'codex'),
      CLAUDE_CONFIG_DIR: path.join(engines, 'claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: path.join(engines, 'claude'),
      TATWO2_OS_SOCKET: path.join(base, 'os.sock'), TATWO2_BROWSER_SOCKET: path.join(base, 'browser.sock'),
      TATWO2_OS_ROOT: entry, TATWO2_DOCS_ROOT: entry,
      TATWO2_OS_UPSTREAM_PATH: path.join(entry, 'os.md'), TATWO2_SKILLET_PATH: path.join(entry, 'skillet.md'),
      TATWO2_SELFTEST: 'w185tools', TATWO2_SKIP_ENGINE_LOGIN: '1',
      TATWO2_SELFTEST_NODE: fixtureNode,
    };
    for (const key of Object.keys(env)) {
      if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
    }
    const supplied = process.env.TATWO2_TEST_BINARY;
    // SwiftPM architecture output and the room builder's Xcode-backed debug symlink share one scratch root.
    const binary = fs.existsSync(supplied) ? supplied : path.join(path.dirname(path.dirname(path.dirname(supplied))), 'debug', 'Tatwo2');
    const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 160_000, maxBuffer: 4 * 1024 * 1024 });
    fs.writeFileSync(path.join(base, 'selftest.log'), (result.stdout ?? '') + (result.stderr ?? ''));
    console.log(`W185TOOLS binary ${binary}; selftest evidence ${path.join(base, 'selftest.log')}`);
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /W185CU SUMMARY passed=\d+ failures=0/);
    assert.doesNotMatch(result.stdout, /W185CU FAIL/);
    assert.match(result.stdout, /W185TOOLS SUMMARY passed=\d+ failures=0/);
    assert.doesNotMatch(result.stdout, /W185TOOLS FAIL/);
  } finally {
    if (fixtureNodeDirectory) fs.rmSync(fixtureNodeDirectory, { recursive: true, force: true });
  }
});

test('F2-12 private skillet section suppresses every body entry until a public heading', () => {
  const parse = section(skillet, 'static func parse(', 'static func index(');
  assert.match(parse, /var privateSection = false/);
  assert.match(parse, /if line\.hasPrefix\("## "\)/);
  assert.match(parse, /privateSection = .*line\.lowercased\(\)\.contains/);
  assert.match(parse, /if privateSection \{ activeSection = nil; continue \}/);
  assert.ok(parse.indexOf('if privateSection') < parse.indexOf('regex.firstMatch'));
  const readMethod = section(skillet, 'static func read(name:', null);
  assert.match(readMethod, /skills\.first\(where: \{ \$0\.name == name \}\)/);
});
