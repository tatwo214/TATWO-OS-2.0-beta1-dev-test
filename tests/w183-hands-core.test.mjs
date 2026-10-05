import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// W183 R1／R1b：ChatGPT 手腳的 App 核心——原始碼契約（接口 v2＋v3）、fixtures/wire.json 形狀、檔案小幫手（fsop.mjs）的功能測試。
// 真正的沙盒探針（sandbox-exec）、配對、grant、工作區、交件在 App 自測 TATWO2_SELFTEST=w183hands（lead-verify 在 mini 跑）。
const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');
const swift = name => read(`App/Sources/Tatwo2/${name}`);
const fsopPath = path.join(repo, 'Engines/chatgpt-hands/fsop.mjs');
const wire = JSON.parse(read('Engines/chatgpt-hands/fixtures/wire.json'));
const setBody = (source, name) => source.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  return source.slice(from, to < 0 ? source.length : to);
};
const auth = swift('Facade/HandsAuth.swift');
const service = swift('Facade/HandsService.swift');
const tools = swift('Facade/HandsTools.swift');
const rooms = swift('Facade/HandsRooms.swift');
const sandbox = swift('Facade/HandsSandbox.swift');
const jobs = swift('Facade/HandsJobs.swift');
const memory = swift('Facade/HandsMemory.swift');
const bridge = swift('Facade/OSAgentBridge.swift');

test('T7 identity: .externalAI is not bound to a thread, not trusted, not inherited, and only reaches the three hands methods', () => {
  const caller = swift('Facade/OSSocketCaller.swift');
  assert.match(caller, /\n    case externalAI\n/, 'no associated thread (contract v2 §1)');
  assert.match(caller, /enum Root: Equatable \{[\s\S]*case externalAI   \/\/ W183/);
  assert.match(caller, /var inheritable: Bool \{\s*if case \.externalAI = root \{ return false \}/);
  assert.match(caller, /guard entry\.inheritable \|\| current == pid else \{ break \}/);
  assert.match(between(caller, 'var isTrusted: Bool', 'var isLocalApp'), /case \.externalAI, \.other: return false/);
  assert.match(between(caller, 'var isLocalApp: Bool', 'var boundThread'), /case \.ssh, \.externalAI, \.other: return false/);
  assert.match(between(caller, 'var boundThread: UUID?', 'var label'), /case \.app, \.helper, \.ssh, \.externalAI, \.other: return nil/);
  assert.doesNotMatch(between(caller, 'var boundThread: UUID?', 'var label'), /default:/, 'boundThread must list every case');
  assert.match(caller, /case \.externalAI: "externalAI"/);

  const contract = swift('Facade/HandsContract.swift');
  assert.deepEqual(setBody(contract, 'externalAIMethods').match(/"([^"]+)"/g), ['"hands_tools"', '"hands_call"', '"hands_auth"']);
  const register = between(contract, 'static func registerExternalAI', 'static func unregisterExternalAI');
  assert.match(register, /thread _: UUID/, 'thread parameter kept for the signature but ignored');
  assert.match(register, /processStartTime\(pid\) == startTime/);
  assert.match(register, /externalAIs = \[pid: RootEntry\(root: \.externalAI, startTime: startTime\)\]/, 'one gateway at a time');
  assert.doesNotMatch(contract, /registerHelper/);

  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods', 'ownedMethods', 'approvalMethods']) {
    assert.doesNotMatch(setBody(bridge, list), /"hands_/, list);
  }
  const allows = between(bridge, 'static func allows(caller:', 'private static let isStagingInstance');
  assert.match(allows, /if case \.externalAI = caller \{ return HandsContract\.externalAIMethods\.contains\(method\) \}/);
  assert.match(allows, /if HandsContract\.externalAIMethods\.contains\(method\) \{ return false \}/);
  assert.ok(allows.indexOf('if case .externalAI = caller') < allows.indexOf('DistillRemoteRequest.methods'));
  assert.match(allows, /case \.externalAI:\n\s*return false/);
  const handle = between(bridge, 'private func handle(clientFD:', 'private func write(_ value');
  const lane = between(handle, 'if case .externalAI = caller {', 'let context = RequestContext(');
  assert.match(lane, /handsSlots\.wait\(timeout: \.now\(\)\) == \.success/);
  assert.match(lane, /handsQueue\.async/);
  assert.match(lane, /Self\.handsResponse\(method: method, params: params\)/);
  assert.match(bridge, /private let handsSlots = DispatchSemaphore\(value: 8\)/);
  const params = between(bridge, 'static func handsParams(', 'static func handsResponse(');
  assert.match(params, /resolved\["callerThreadID"\] = nil/);
  assert.match(params, /resolved\["_threadID"\] = nil/);
  const response = between(bridge, 'static func handsResponse(', 'private static let ownedMethods');
  assert.match(response, /catch let error as HandsWireError \{\s*return \["ok": false, "error": error\.wire\]/);
  assert.match(service, /params\["callerThreadID"\] = nil   \/\/ 接口 v2 §1/);
  assert.doesNotMatch(service, /boundThread|bindingMismatch/, 'no thread binding left in HandsService');

  assert.match(swift('Facade/OSToolsAcceptance.swift'), /for caller in \[OSSocketCaller\.other\(pid: nil\), \.ssh, \.externalAI\]/);
  assert.match(swift('Facade/DistillAcceptance.swift'), /\.other\(pid: nil\), \.externalAI\]/);
  assert.match(swift('Facade/PrimaryOfflineAcceptance.swift'), /\.other\(pid: nil\), \.externalAI\]\.allSatisfy/);
});

test('fixtures/wire.json: every hands_auth op, param, result key and error code has an App counterpart', () => {
  const handleOps = between(auth, 'func handle(op: String', 'private func requireKeys');
  const opFunctions = { register_client: 'registerClient', authorize_begin: 'authorizeBegin', authorize_submit: 'authorizeSubmit', token: 'token', check: 'checkOp' };
  for (const [op, spec] of Object.entries(wire.hands_auth)) {
    assert.ok(handleOps.includes(`case "${op}"`), op);
    const fn = opFunctions[op];
    const body = between(auth, `private func ${fn}(`, '\n    }\n');
    const allowed = new Set([...(body.match(/requireKeys\(params, \[([^\]]*)\]\)/)?.[1] ?? '').matchAll(/"([^"]+)"/g)].map(m => m[1]).concat('op'));
    for (const example of ['params', 'params_authorization_code', 'params_refresh_token']) {
      for (const key of Object.keys(spec[example] ?? {})) assert.ok(allowed.has(key), `${op}.${example}.${key}`);
    }
    for (const key of Object.keys(spec.result ?? {})) {
      const scope = op === 'token' ? between(auth, 'private func issueLocked', '\n    }\n') : body;
      assert.ok(scope.includes(`"${key}"`), `${op} result key ${key}`);
    }
    for (const failure of spec.errors ?? []) {
      assert.ok(auth.includes(`code: "${failure.error.code}"`), `${op} error ${failure.error.code}`);
      assert.ok(auth.includes(`message: "${failure.error.message}"`) || auth.includes(`invalidRequest("${failure.error.message}")`),
        `${op} error message ${failure.error.message}`);
      if ('attempts_left' in failure.error) assert.match(auth, /error\["attempts_left"\] = attemptsLeft/);
    }
  }
  assert.match(between(auth, 'private func checkOp(', '\n    }\n'), /return \["ok": false\]/, 'check: result_invalid');
  // 交易編號 4 碼（網頁上同一組）、transaction_id 帶 tx_ 前綴、到期時間 ISO 8601。
  assert.match(auth, /Transaction\(id: "tx_" \+ Self\.random\(bytes: 12\), displayCode: Self\.code\(length: 4\), pairingCode: Self\.code\(length: 8\)/);
  assert.match(auth, /"expires_at": formatter\.string\(from: created\.expiresAt\)/);
  // hands_tools／hands_call。
  const handle = between(service, 'func handle(method: String, params raw:', 'private func authorized');
  for (const key of Object.keys(wire.hands_tools.params)) assert.ok(handle.includes(`"${key}"`), `hands_tools ${key}`);
  for (const key of Object.keys(wire.hands_call.params)) assert.ok(between(handle, 'case "hands_call":', 'default:').includes(`"${key}"`), `hands_call ${key}`);
  for (const key of Object.keys(wire.hands_tools.result)) assert.ok(handle.includes(`"${key}"`), `hands_tools result ${key}`);
  for (const example of wire.hands_tools.result.tools) {
    const spec = between(tools, `HandsToolSpec(id: "${example.name}"`, 'HandsToolSpec(id:');
    for (const property of Object.keys(example.inputSchema.properties)) assert.ok(spec.includes(`"${property}"`), `${example.name}.${property}`);
    for (const required of example.inputSchema.required) assert.match(spec, new RegExp(`required: \\[[^\\]]*"${required}"`), `${example.name} requires ${required}`);
  }
  assert.match(tools, /"additionalProperties": false/);
  assert.match(service, /var content: \[\[String: Any\]\] = \[\["type": "text", "text": HandsRedactor\.clip\(text, limit: 120_000\)\]\]/);
  assert.match(service, /return \["content": content, "isError": isError\]/);
  const inProgress = JSON.parse(wire.hands_call.result_in_progress.content[0].text);
  assert.equal(inProgress.status, 'running');
  assert.match(service, /var status: \[String: Any\] = \["status": "running"\]\s*\n\s*if let job \{ status\["job_id"\] = job \}/);
  for (const failure of wire.hands_call.errors) assert.ok(auth.includes(`code: "${failure.error.code}"`), failure.error.code);
  const readExample = JSON.parse(wire.hands_call.result.content[0].text);
  const fsopSource = read('Engines/chatgpt-hands/fsop.mjs');
  for (const key of Object.keys(readExample)) assert.ok(fsopSource.includes(key), `read_file result ${key}`);
});

test('T2/T3/T15 pairing window, confirmation card, grants and tokens (v2 §3–§5, v3 V9, V13, V15, V17)', () => {
  assert.match(auth, /static let windowLifetime: TimeInterval = 600/);
  assert.match(auth, /static let pairingAttempts = 5/);
  assert.match(auth, /static let codeLifetime: TimeInterval = 60/);
  assert.match(auth, /static let accessLifetime: TimeInterval = 3600/);
  assert.match(auth, /static let refreshLifetime: TimeInterval = 30 \* 86_400/);
  assert.match(auth, /static let codeAlphabet = Array\("23456789ABCDEFGHJKLMNPQRSTUVWXYZ"\)/);
  const begin = between(auth, 'private func authorizeBegin(', 'private func authorizeSubmit(');
  // 窗口外一律拒；一次一筆；redirect 精確在設定清單；S256。
  assert.ok(begin.indexOf('HandsWireError.windowClosed') < begin.indexOf('Transaction('));
  assert.match(begin, /HandsWireError\.pairingBusy/);
  assert.match(begin, /context\.callbacks\.contains\(redirect\)/);
  assert.match(begin, /params\["code_challenge_method"\] as\? String == "S256"/);
  // 配對碼只給畫面：回傳只有交易編號、顯示碼、期限。
  const returned = begin.slice(begin.indexOf('return ["transaction_id"'));
  assert.doesNotMatch(returned, /pairingCode|pairing_code/);
  // W183 R6b：綁連線意圖的窗口用按［連線］時拍下的範圍（window.scope），手動的照舊用這次的設定。
  assert.match(begin, /scope: window\.scope \?\? context\.scope/, 'card carries level, projects and memory scope snapshot');
  const submit = between(auth, 'private func authorizeSubmit(', 'private func token(');
  assert.match(submit, /Self\.isBindingHash\(binding\)/);
  assert.match(submit, /pending\.submits\.count < 10/, 'per-transaction rate limit (V13)');
  assert.match(submit, /self\.window = nil/);
  const register = between(auth, 'private func registerClient(', 'private func authorizeBegin(');
  assert.match(register, /context\.callbacks\.contains\(\$0\)/);
  assert.match(register, /maxPendingClients/);
  // refresh 重用＝撤銷該 grant（V15）；授權碼重用＝撤銷它換到的 grant。
  const token = between(auth, 'private func tokenLocked(', 'private func issueLocked(');
  assert.match(token, /revokeLocked\(\[used\.grantID\], reason: "refresh_reused"\)/);
  assert.match(token, /revokeLocked\(\[grant\], reason: "code_reused"\)/);
  assert.match(token, /allow\("token:" \+ clientID, max: 20, per: 60\)/);
  assert.match(token, /HandsAuthState\.Grant\(id: "g_" \+ Self\.hex\(bytes: 10\), clientID: clientID, level: entry\.level,\s*projectIDs: entry\.projectIDs/);
  // 撤銷不開給關口；狀態檔只存雜湊。
  assert.doesNotMatch(between(auth, 'func handle(op: String', 'private func requireKeys'), /revoke/);
  assert.doesNotMatch(between(auth, 'struct Token: Codable', 'struct UsedRefresh'), /var (access|refresh)Token|var token:/);
  assert.match(service, /let scope = op == "authorize_begin" \? grantScope\(current\)/);
  assert.match(service, /return \["level": level, "tools": HandsTools\.catalog\(level: level\)\.map\(\\\.descriptor\)\]/);
  assert.match(service, /let level = min\(grant\.grantLevel, current\.level\)/);
  const settings = swift('Facade/HandsSettings.swift');
  assert.match(settings, /static let rootFolderName = "TATWO OS Hands"/);
  assert.match(settings, /var settingsFile: URL \{ appDir\.appendingPathComponent\("settings\.json"\) \}/, 'same file R2 reads (v2 §10)');
  assert.match(settings, /O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC, mode_t\(0o600\)/);
  assert.match(settings, /\(info\.st_mode & 0o077\) == 0/);
  assert.match(settings, /case chatgptCallbacks = "chatgpt_callbacks"/);
  assert.match(settings, /var enabled: Bool = false/, 'off unless the user turns it on');
  const state = swift('Facade/HandsState.swift');
  for (const needle of ['pairingWindowExpiresAt', 'pendingPairing: HandsPairingCard?', 'func startPairing()', 'func cancelPendingPairing()', 'func revokeGrant(']) {
    assert.ok(state.includes(needle), needle);
  }
  assert.match(state, /授權這筆連線/);
  assert.doesNotMatch(state, /已驗證/);
});

test('V9 grant owns everything; switching off, lowering the level or removing a project cancels work and locks workspaces', () => {
  const resolve = between(rooms, 'func workspace(_ raw: String, grant:', 'func target(workspaceID:');
  assert.match(resolve, /record\.grantID == grant\.grantID else \{\s*throw HandsToolError\.invalid\("workspace_not_found"\)/);
  assert.match(resolve, /allowedProjectIDs\(grant, settings\)\.contains\(record\.projectID\.uuidString\)/);
  // W183 R10（全部可見；取代「本機清單 ∩ grant」）：有效專案＝這台全部看得到的（新專案自動加入）∩ grant 核准的（grant 核准「全部」＝一樣是這台全部）；
  // 舊設定（沒有 allProjects）照舊是本機清單 ∩ grant。grant 照樣擁有一切：跨 grant 的工作區、工作、記憶一律拿不到（下面幾條）。
  assert.match(rooms, /let host = Set\(visibleProjectRecords\(\)\.map \{ \$0\.0\.uuidString \}\)\s*let setting = settings\.allProjects \? host : Set\(settings\.allowedProjectIDs\)\s*let granted = grant\.allProjects \? host : Set\(grant\.projectIDs\)\s*return setting\.intersection\(granted\)/);
  assert.match(rooms, /workspaceStore\.all\(\)\.filter \{ \$0\.grantID == grant\.grantID \}/);
  assert.match(rooms, /grantID: grant\.grantID, projectID: project\.id/);
  assert.match(jobs, /guard let job = jobs\[id\], job\.grantID == grant else \{ return nil \}/);
  assert.match(jobs, /meta\["grant_id"\] as\? String == grant/);
  assert.match(memory, /\$0\.1\.grantID == grant\.grantID/);
  const update = between(service, 'func updateSettings(', 'func setEnabled(');
  assert.match(update, /if old\.enabled && !new\.enabled \{\s*revocationProblem = auth\.revokeAll\(reason: "switched_off"\)/);
  assert.match(update, /reason: "level_lowered"/);
  assert.match(update, /reason: "project_removed"/);
  assert.match(between(service, 'func grantsRevoked(', 'func revokeEverything('), /workspaceStore\.lock\(where: \{ set\.contains\(\$0\.grantID\) \}/);
});

test('V2/V7/T6/T11 sandbox: deny-default, no network, no Homebrew, protected names at any depth and case, other workspaces denied, limits, marks', () => {
  assert.match(sandbox, /static let sandboxExec = "\/usr\/bin\/sandbox-exec"/);
  assert.match(sandbox, /"\(deny default\)"/);
  assert.doesNotMatch(sandbox, /\(allow default\)/);
  assert.match(sandbox, /"\(deny network\*\)"/);
  assert.match(sandbox, /\(deny mach-lookup \(xpc-service-name-prefix \\"\\"\)\)/);
  for (const binary of ['/usr/bin/open', '/usr/bin/osascript', '/usr/bin/security', '/bin/launchctl', '/usr/bin/ssh', '/usr/bin/sudo']) {
    assert.ok(sandbox.includes(`"${binary}"`), binary);
  }
  const names = between(sandbox, 'static let protectedNames', 'static let protectedPaths');
  for (const name of ['.git', '.gitattributes', '.gitmodules', '.tatwo2', '.claude', '.codex', '.agents', '.cursor', '.vscode', '.mcp.json',
    'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.cursorrules', '.windsurfrules']) assert.ok(names.includes(`"${name}"`), name);
  assert.match(sandbox, /static let protectedPaths: \[String\] = \["\.github\/copilot-instructions\.md"\]/);
  assert.match(sandbox, /static let guardedDirectories: \[String\] = \["\.github"\]/);
  // 大小寫都算：字母寫成 [xX]、點寫成 [.]；只作用在工作區（subpath WS）。
  assert.match(sandbox, /result \+= "\[\\\(character\.lowercased\(\)\)\\\(character\.uppercased\(\)\)\]"/);
  assert.match(sandbox, /\(deny file-write\* \(require-all \(subpath \(param \\"WS\\"\)\) \(regex #\\"\\\(protectedPattern\)\\"\)\)\)/);
  assert.match(sandbox, /\(regex #\\"\\\(protectedPathPattern\)\\"\)/);
  assert.match(sandbox, /\(regex #\\"\\\(guardedDirectoryPattern\)\\"\)/);
  assert.match(sandbox, /\(deny file-write-unlink \(literal \(param \\"WS\\"\)\)\)/);
  assert.match(sandbox, /\(require-all \(subpath \\\(param\("WS_ROOT", root\)\)\) \(require-not \(subpath \\\(param\("WS_DIR", own\)\)\)\)\)/);
  // V2：系統工具鏈＋內附 node；Homebrew 不在允許清單、明確拒絕；PATH 沒有 Homebrew。
  const allowRead = between(sandbox, '"(allow file-read* (literal', '(subpath \\"/dev/fd\\"))"');
  assert.doesNotMatch(allowRead, /homebrew|usr\/local/);
  assert.match(sandbox, /if !paths\.allowHomebrew \{ lines\.append\("\(deny file-read\* file-write\* \(subpath \\"\/usr\/local\\"\) \(subpath \\"\/opt\/homebrew\\"\)\)"\) \}/);
  const env = between(sandbox, 'static func environment(scratch:', 'static func prepareScratch(');
  assert.doesNotMatch(env, /homebrew|usr\/local/);
  assert.match(env, /"npm_config_offline": "true", "npm_config_ignore_scripts": "true"/);
  assert.match(env, /"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp \+ "\/"/);
  assert.doesNotMatch(env, /ProcessInfo|SSH_AUTH_SOCK|TATWO2_|_TOKEN|_KEY"/);
  assert.match(rooms, /paths\.allowHomebrew = true/);
  assert.match(between(rooms, 'func sandboxPaths(', 'func sandboxEnvironment('), /else if forHelper \{/, 'Homebrew node only for the App helper (DEBUG)');
  assert.match(jobs, /sandboxPaths\(mode: \.worker, workspace: workspace, scratch: workspace\.scratch, forHelper: false\)/, 'ChatGPT commands never get Homebrew');
  assert.match(service, /#if DEBUG\s*\n\s*for candidate in \["\/opt\/homebrew\/bin\/node"/, 'Homebrew node only in DEBUG builds');
  // 四種規則；交件小幫手只准寫工作區 .git。
  assert.match(sandbox, /enum Mode: Equatable \{ case worker, readOnly, export, commit \}/);
  assert.match(sandbox, /case \.commit:\s*\n\s*if let ws = paths\.workspace \{ writes\.append\("\(subpath \\\(param\("WS_GIT", ws \+ "\/\.git"\)\)\)"\) \}/);
  // 標記（這次、工作區、全體）；脫離群組的收掉；proc_pidinfo 掃 cwd 與寫入中的檔案（V10）。
  assert.match(sandbox, /if let ws = marks\.workspace \{ allowed\.append\("\(literal \\\(param\("MARK_WS", ws\)\)\)"\) \}/);
  assert.match(sandbox, /isSandboxed\(pid\) && readDenied\(pid, mark\) == 0 && readDenied\(pid, control\) == 1/);
  const writers = between(sandbox, 'static func writers(in roots:', 'static func processName(');
  assert.match(writers, /PROC_PIDVNODEPATHINFO/);
  assert.match(writers, /PROC_PIDFDVNODEPATHINFO/);
  assert.match(writers, /fi_openflags & 0x2/);
  const quiesce = between(sandbox, 'static func quiesce(', 'static func spawnAndWait(');
  assert.match(quiesce, /terminate\(where: \{ \$0\.workspace == id \}/);
  assert.match(quiesce, /found\.filter\(\\\.ours\)/);
  assert.match(sandbox, /POSIX_SPAWN_SETPGROUP\) \| Int32\(POSIX_SPAWN_CLOEXEC_DEFAULT\)/);
  assert.match(sandbox, /posix_spawn_file_actions_addopen\(&actions, STDIN_FILENO, "\/dev\/null", O_RDONLY, 0\)/);
  const limits = between(sandbox, 'static func limitScript(', 'static func clamp(');
  assert.match(limits, /"limit \\\(\$0\.0\) \\\(\$0\.1\) && limit -h \\\(\$0\.0\) \\\(\$0\.1\)"/);
  for (const name of ['coredumpsize', 'cputime', 'filesize', 'maxproc']) assert.ok(limits.includes(`("${name}", `), name);
  assert.match(limits, /exit 125 \}; exec \\"\$@\\""/);
  assert.match(sandbox, /network_volume_refused/);
  const redactor = between(sandbox, 'enum HandsRedactor', undefined);
  for (const needle of ['\\\\bsk-', 'Bearer', 'github_pat_', 'tatwoh_(?:at|rt|ac)_', '/Users/', 'PRIVATE KEY', '://']) assert.ok(redactor.includes(needle), needle);
  // 沙盒一律拒：TATWO OS Hands 的私有區（設定、OAuth、輸出、關口）。
  assert.match(swift('Facade/HandsSettings.swift'), /\[appDir, outputDir, root\.appendingPathComponent\("gateway", isDirectory: true\)/);
  assert.match(service, /list \+= paths\.privateAreas\.map\(\\\.path\)/);
});

test('V1/V3/V4 export: git archive of a fixed base SHA through a clean shadow gitdir, APFS clone for dependencies, nothing is installed', () => {
  const open = between(rooms, 'func openWorkspace(', 'func archiveWorkspaceFolder(');
  assert.match(open, /let base = try projectHead\(project\)/);
  assert.match(open, /archive --format=tar "\$sha" \| \/usr\/bin\/tar -x -f - -C "\$ws"/);
  assert.match(open, /init -q --template= \./);
  assert.match(open, /commit -q --no-verify --allow-empty -m "TATWO 基準 \$sha"/);
  assert.match(open, /sandboxPaths\(mode: \.export, workspace: workspace, scratch: scratch, readOnly: \[shadow, git\.objects\]/);
  assert.match(open, /\["\/bin\/cp", "-c", "-R", "--", source, target\]/);
  assert.match(open, /project_must_be_git_top_level/);
  assert.match(open, /pathClashesWithRules\(repo\)/);
  assert.doesNotMatch(rooms + jobs, /npm (ci|install)|swift package resolve|pod install|bundle install/);
  // W183 R10 第二輪（GPT-6 4）：不帶 .build/repositories（沒清過的 Git 物件庫，git show 讀得到舊檔）；帶進來的依賴再濾（.git、金鑰類拿掉）。
  assert.match(rooms, /static let dependencyCandidates = \["\.build\/checkouts", "node_modules"\]/);
  assert.match(rooms, /if copy\.exitCode == 0, sanitizeDependency\(target, workspace: workspace, scratch: scratch, admit: admit\) \{ copied\.append\(candidate\) \}/);
  const shadow = between(rooms, 'func makeShadow(common:', 'func removeShadow(');
  assert.match(shadow, /symlink\(objects, dir \+ "\/objects"\)/);
  assert.match(shadow, /"--get-regexp", pattern/);
  assert.doesNotMatch(shadow, /remote|credential|extraheader|filter|hooks|include/i);
  assert.match(rooms, /project_uses_git_alternates/);
  assert.match(swift('Facade/HandsSettings.swift'), /func repo\(_ id: UUID\) -> URL \{ workspaceDir\(id\)\.appendingPathComponent\("repo", isDirectory: true\) \}/);
  // 專案主線只從 git 物件讀（在沙盒裡、影子 gitdir）。
  const project = between(rooms, 'func projectRead(', '// MARK: - 沙盒裡的 git status');
  assert.match(project, /\["cat-file", "--batch"\], stdin: Data\(\(head \+ ":" \+ joined \+ "\\n"\)\.utf8\)/);
  assert.match(project, /"grep", "-n", "--column", "-I", "--no-color", "--full-name", "--no-textconv", "-z", "-C", "2"/);
});

test('V5/V10/T16 submit: stop writers, commit inside the sandbox, build the candidate with a temporary index, never check out', () => {
  const submit = between(rooms, 'func submitWorkspace(', 'func enforceDiskQuota(');
  const order = ['HandsSandbox.quiesce(', 'Self.nestedGitEntry(', 'mode: .commit', '"--binary", "--full-index"', '["read-tree", base]',
    '["apply", "--cached", "--binary"', '["write-tree"]', '["commit-tree", "--no-gpg-sign"', 'validateCandidate(', '["update-ref"'];
  let last = -1;
  for (const step of order) {
    const at = submit.indexOf(step);
    assert.ok(at > last, `step order: ${step}`);
    last = at;
  }
  assert.match(submit, /workspace_writers_remain/);
  assert.match(submit, /let indexEnv = \["GIT_INDEX_FILE": index\]/);
  assert.doesNotMatch(submit, /"checkout"|"merge"|"reset"|"switch"/);
  assert.match(submit, /extraEnvironment: HandsGit\.identity/);
  assert.match(rooms, /static let authorEmail = "chatgpt-hands@localhost"/);
  const validate = between(rooms, 'func validateCandidate(', 'func submitWorkspace(');
  assert.match(validate, /HandsSandbox\.isProtected\(path: path\)/);
  assert.match(validate, /gitlink_refused/);
  assert.match(validate, /symlink_outside_workspace/);
  assert.match(validate, /file_too_large/);
  assert.match(validate, /（可執行）/);
  assert.match(rooms, /static let hardening = \["-c", "core\.fsmonitor=false", "-c", "core\.hooksPath=\/dev\/null"/);
  assert.match(rooms, /"-c", "core\.splitIndex=false"/);
  assert.match(rooms, /for key in env\.keys where key\.hasPrefix\("GIT_"\) \{ env\[key\] = nil \}/);
  assert.match(rooms, /env\["GIT_CONFIG_GLOBAL"\] = "\/dev\/null"/);
  assert.match(rooms, /static let diskQuota: Int64 = 2 \* 1024 \* 1024 \* 1024/);
  assert.match(jobs, /locked = service\.enforceDiskQuota\(current\)/, 'disk measured after every command');
});

test('V6 review and merge: Hands backend, fixed candidate SHA, main-line advance flagged, no copy-merge command', () => {
  const git = swift('New/DispatchGit.swift');
  assert.match(git, /var handsCandidate: String\? = nil/);
  assert.match(git, /if handsCandidate != nil \{ throw DispatchGitFailure\(message: "ChatGPT 手腳的房間不提供複製合併指令/);
  assert.match(git, /if let candidate = context\.handsCandidate \{ try validateHands\(context, candidate: candidate\); return \}/);
  assert.match(git, /guard ref == candidate else \{ throw DispatchGitFailure\(message: "候選版本已經換了/);
  assert.match(git, /let range = "\\\(base\)\.\.\\\(context\.handsCandidate \?\? branch\)"/);
  assert.match(git, /主線已前進/);
  assert.match(git, /"-c", "core\.fsmonitor=false", "--no-pager"\] \+ extra \+ args/);
  // W183 R1b（T16）：Hands 專用合併——每次重讀設定；merge driver／從工作樹讀的設定＝拒絕；filter 全關；先預演；index 等於預演才提交。
  assert.match(git, /let extra: \[String\] = try context\.handsCandidate == nil \? \[\] : HandsMergeGuard\.plan\(context\)\.flags/);
  assert.match(git, /HandsMergeGuard\.rehearse\(context, plan: \$0, head: current\.head, candidate: current\.branchHead\)/);
  const handsMerge = between(git, 'private static func handsMerge(', 'private static func restoreAfterFailedMerge(');
  assert.match(handsMerge, /"merge", "--no-ff", "--no-commit", "--no-stat", "--no-verify-signatures"/);
  assert.match(handsMerge, /guard staged == tree else/);
  assert.match(handsMerge, /"commit", "--no-verify"/);
  const guard = between(swift('Facade/HandsReview.swift'), 'enum HandsMergeGuard', undefined);
  assert.match(guard, /"config", "-z", "--show-origin", "--list"/);
  assert.match(guard, /lower\.hasPrefix\("merge\."\), lower\.hasSuffix\("\.driver"\)/);
  assert.match(guard, /git 設定會讀專案工作樹裡的檔/);
  assert.match(guard, /"-c", "filter\.\\\(name\)\.clean=", "-c", "filter\.\\\(name\)\.smudge=", "-c", "filter\.\\\(name\)\.process="/);
  assert.match(guard, /"filter\.\\\(name\)\.required=false"/);
  assert.match(guard, /"merge-tree", "--write-tree", "-z", "--name-only", "--no-messages"/);
  assert.match(guard, /"check-attr", "-z", "--stdin", "filter"/);
  assert.match(guard, /plan\.commands\.first\(where: \{ \$0\.contains\(path\) \}\)/);
  for (const flag of ['gc.auto=0', 'maintenance.auto=false', 'submodule.recurse=false', 'merge.renormalize=false', 'merge.verifySignatures=false']) {
    assert.ok(guard.includes(`"${flag}"`), flag);
  }
  const engine = swift('Facade/DispatchEngine.swift');
  assert.match(engine, /if let hands = try handsDispatchGitContext\(id\) \{ return hands \}/);
  assert.match(engine, /handsMarkReviewed\(context, truncated: diff\.truncated\)/);
  assert.match(engine, /let handsNote = try handsMergeCheck\(context, preview: preview\)/);
  assert.match(engine, /again\.handsCandidate == context\.handsCandidate/);
  const review = swift('Facade/HandsReview.swift');
  assert.match(review, /seen\.candidate == candidate, preview\.branchHead == candidate/);
  assert.match(review, /主線已前進/);
  assert.match(swift('New/DispatchCard.swift'), /if !model\.isHandsRoom\(room\.id\) \{[^\n]*\n\s*Button\("複製合併指令"\)/);
  assert.match(swift('New/DispatchCard.swift'), /if !model\.isHandsRoom\(room\.id\) \{[^\n]*\n\s*Button\("退回重做"\)/);
});

test('W183 R1b review fixes: truncation, admission, submit lock, scan certainty, revocation persistence, redaction, disk, replay', () => {
  // 截斷＝拒絕；候選紀錄每一筆都要完整。
  assert.match(rooms, /guard !result\.truncated else \{ throw HandsToolError\.invalid\("git_output_too_large/);
  assert.match(between(rooms, 'func validateCandidate(', 'func submitWorkspace('), /candidate_listing_malformed/);
  // 啟動前最後一次授權檢查跟登記群組同一把鎖；撤銷、設定改變跟發布互斥；交件期間禁止新寫入者。
  const spawn = between(sandbox, 'static func spawnAndWait(', 'static func diskUsage(');
  assert.ok(spawn.indexOf('liveLock.lock()') < spawn.indexOf('let refusal = admit?()'));
  assert.ok(spawn.indexOf('let refusal = admit?()') < spawn.indexOf('posix_spawn(&pid'));
  assert.ok(spawn.indexOf('posix_spawn(&pid') < spawn.indexOf('liveGroups[pid] = tag ?? RunTag()'));
  assert.ok(spawn.indexOf('liveGroups[pid] = tag ?? RunTag()') < spawn.indexOf('liveLock.unlock()'));
  const admission = between(service, 'func admissionProblem(', '/// 給 HandsSandbox.run 的 admit');
  for (const reason of ['grant_revoked', 'hands_off', 'level_lowered', 'project_not_allowed', 'workspace_locked', 'workspace_submitting']) {
    assert.ok(admission.includes(`"${reason}"`), reason);
  }
  assert.doesNotMatch(admission, /onMain|HandsSandbox\./, 'runs under the sandbox lock: no main thread, no re-entry');
  assert.match(between(service, 'func grantsRevoked(', 'func revokeEverything('), /publicationLock\.lock\(\)/);
  assert.match(between(service, 'func updateSettings(', 'func setEnabled('), /publicationLock\.lock\(\)/);
  assert.match(jobs, /admit: admit,/);
  // 守：job_start 在工作區的寫入鎖裡啟動（W183 R10 第三輪：鎖裡先把新出現的金鑰類檔搬去隔離，才啟動）。
  assert.match(tools, /let \(job, _\) = try service\.withWorkspaceLock\(workspace\) \{ \(\) throws -> \(HandsJobs\.Job, DispatchSemaphore\) in\s*\/\/[^\n]*\n\s*try service\.quarantineNewSecrets\(workspace\)\s*return try service\.jobs\.start/);
  const submit = between(rooms, 'func submitWorkspace(', 'func enforceDiskQuota(');
  assert.ok(submit.indexOf('beginSubmitting(workspace.id)') < submit.indexOf('HandsSandbox.quiesce('));
  assert.match(submit, /case \.unknown\(let reason\):\s*\n\s*workspaceStore\.lock\(where: \{ \$0\.id == workspace\.id \}, reason: "writers_unverifiable"\)/);
  assert.match(submit, /protectedDrift\(workspace\)/);
  assert.match(submit, /try withPublication\(grantID: grant\.grantID[\s\S]*"update-ref"/);
  // 掃描：列舉失敗、探針不在＝無法判定；資料夾 fd 也算。
  assert.match(sandbox, /static func userProcessesChecked\(\) -> \[ProcessEntry\]\?/);
  assert.match(between(sandbox, 'static func quiesce(', 'static func spawnAndWait('), /guard Self\.probe != nil else \{ return \.unknown\("sandbox_probe_unavailable"\) \}/);
  assert.match(sandbox, /S_IFMT\)\) == UInt32\(S_IFDIR\)/);
  // 撤銷存不了檔＝全部停用、刪授權檔；用過的 refresh 在偵測期內不淘汰。
  const persist = between(auth, 'private func persistRevocationLocked(', '// MARK: - 小工具');
  assert.match(persist, /unlink\(url\.path\)/);
  assert.match(persist, /persistenceFailure = problem/);
  assert.doesNotMatch(auth, /try\? saveLocked\(\)/);
  assert.doesNotMatch(auth, /usedRefresh\.removeFirst/);
  assert.match(auth, /guard persistenceFailure == nil else \{ return nil \}/);
  // 遮蔽：整個檔／整段輸出一起算，寫盤前遮；分頁、截斷、搜尋拿不回秘密。
  const secrets = swift('Facade/HandsSecrets.swift');
  assert.match(secrets, /static func classify\(_ line: String, state: inout State\) -> Kind\?/);
  assert.match(secrets, /final class HandsStreamRedactor/);
  assert.match(between(jobs, 'private func capture(', 'private func flush('), /\.feed\(raw\)/);
  assert.match(rooms, /let kinds = HandsSecretLines\.mask\(raw\)/);
  assert.match(rooms, /HandsSecretLines\.maskDiff/);
  assert.match(rooms, /"-----\(BEGIN\|END\) \[A-Z0-9 \]\*PRIVATE KEY-----"/);
  // 磁碟：寫檔也算、低水位、跑的時候看、輸出區總量與保留；帳本總量。
  assert.match(tools, /try service\.requireDiskRoom\(adding: incoming\)\s*\n\s*try service\.quotaCheck\(workspace, adding: incoming\)/);
  assert.match(jobs, /service\.freeDiskBytes\(\) < service\.diskLowWaterBytes \/ 2/);
  assert.match(jobs, /static let outputRetention: TimeInterval = 7 \* 86_400/);
  assert.match(jobs, /static let maxLedgerBytes = 256 \* 1024 \* 1024/);
  assert.match(rooms, /static let maxWorkspacesPerGrant = 32/);
  // 重送：只讀的工具不重播；會改東西的重播前重查授權。帳本整段同一把鎖。
  assert.match(service, /if let requestID, !tool\.readOnly, !name\.hasPrefix\("computer_"\) \{/);
  assert.match(service, /if let problem = replayProblem\(arguments: arguments, grant: grant, settings: current\)/);
  const reserve = between(jobs, 'func reserve(grant:', 'func attachJob(');
  assert.ok(reserve.indexOf('lock.lock(); defer { lock.unlock() }') < reserve.indexOf('HandsFiles.createExclusive'));
  assert.doesNotMatch(reserve, /unlink/);
  // V7：保護項目的上層資料夾不准改名；開工作區記下保護項目，之後被繞過就鎖住。
  assert.match(sandbox, /"\(deny file-write\* " \+ literals\.joined\(separator: " "\) \+ "\)"/);
  assert.match(rooms, /record\.protectedManifest = try Self\.protectedEntries\(in: repo, skipping: copied\)/);
  // apply_patch 還原失敗不說「什麼都沒改」；App 鎖住工作區。
  assert.match(tools, /reason\.hasPrefix\("patch_partially_applied"\)/);
});

test('Tools: exactly the v2 §7 table (+v3 + W185 CU/skillet + W225 collaboration), levels, schemas, job limits, request_id ledger, output area', () => {
  const specs = [...tools.matchAll(/HandsToolSpec\(id: "([a-z_]+)", level: (\d)/g)].map(match => [match[1], Number(match[2])]);
  assert.deepEqual(Object.fromEntries(specs), {
    tatwo_status: 0, list_projects: 0, read_session: 0, create_project: 1, list_workspaces: 0, read_file: 0, list_dir: 0, search: 0, git_status: 0, git_diff: 0,
    memory_search: 1, memory_get: 1, memory_inbox_save: 1, memory_inbox_list: 1, propose_goal: 1, write_report: 1,
    skillet_list: 1, skillet_read: 1,
    computer_request: 2, computer_status: 2, computer_observe: 2, computer_action: 2, computer_stop: 2,
    open_workspace: 2, write_file: 2, edit_file: 2, apply_patch: 2, run_command: 2, job_start: 2, job_status: 2, job_output: 2,
    job_cancel: 2, submit_workspace: 2,
  });
  for (const forbidden of ['dispatch', 'cli_', 'send_message', 'transcript', 'merge', 'device', 'ssh', 'memory_save', 'background', 'read_lent']) {
    assert.ok(!specs.some(([name]) => name.includes(forbidden)), forbidden);
  }
  assert.match(between(tools, 'HandsToolSpec(id: "write_file"', 'HandsToolSpec(id: "edit_file"'), /"expected_sha256"[\s\S]*"create_only"/);
  assert.match(between(tools, 'HandsToolSpec(id: "edit_file"', 'HandsToolSpec(id: "apply_patch"'), /required: \["workspace_id", "path", "old_string", "new_string", "expected_sha256"\]/);
  assert.match(between(tools, 'HandsToolSpec(id: "git_diff"', 'HandsToolSpec(id: "memory_search"'), /choice\("worktree or base", \["worktree", "base"\]\)/);
  assert.match(between(tools, 'HandsToolSpec(id: "run_command"', 'HandsToolSpec(id: "job_start"'), /maximum: 45/);
  assert.match(between(tools, 'HandsToolSpec(id: "job_start"', 'HandsToolSpec(id: "job_status"'), /maximum: 600/);
  assert.doesNotMatch(between(tools, 'HandsToolSpec(id: "memory_inbox_save"', 'HandsToolSpec(id: "memory_inbox_list"'), /"source"|"verified"|"grant_id"/);
  assert.match(tools, /static func catalog\(level: Int\) -> \[HandsToolSpec\] \{ all\.filter \{ \$0\.level <= level \} \}/);
  assert.match(service, /guard let tool = HandsTools\.tool\(named: name\), tool\.level <= level else \{ throw HandsWireError\.toolNotAllowed \}/);
  assert.match(jobs, /static let perGrant = 2/);
  assert.match(jobs, /static let global = 3/);
  assert.match(jobs, /static let outputCap = 8 \* 1024 \* 1024/);
  assert.match(jobs, /static let syncLimit: TimeInterval = 45/);
  assert.match(swift('Facade/HandsSettings.swift'), /outputDir\.appendingPathComponent\(grant, isDirectory: true\)\.appendingPathComponent\(job, isDirectory: true\)/);
  assert.match(jobs, /O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC \| O_APPEND, mode_t\(0o600\)/);
  const reserve = between(jobs, 'func reserve(grant:', 'func attachJob(');
  assert.match(reserve, /HandsFiles\.createExclusive\(encode\(fresh\), at: url\(key\)\)/);
  assert.match(reserve, /return \.conflict/);
  assert.match(reserve, /existing\.instance == instance \? \.running\(jobID: existing\.jobID\) : \.interrupted/);
  assert.match(jobs, /HandsAuth\.hash\(grant \+ "\\n" \+ tool \+ "\\n" \+ requestID\)/);
  assert.match(jobs, /static let retention: TimeInterval = 24 \* 3600/);
  const output = between(jobs, 'func output(_ id: String, grant:', 'func cancel(_ id: String');
  assert.match(output, /HandsRedactor\.redactKeyTail\(text\)/);
  assert.match(output, /HandsRedactor\.redact\(text, context: context\)/);
  // 每次都重查：開關、設備、token→grant、等級。
  const authorized = between(service, 'private func authorized(', 'func deviceAllowed(');
  assert.match(authorized, /guard current\.enabled, deviceAllowed\(current\), permitCheck\?\(\) \?\? true else \{ throw HandsWireError\.unauthorized \}/);   // W183 R8c：暫停＝不收
  assert.match(authorized, /auth\.grant\(forAccess: access\)/);
  assert.doesNotMatch(service + swift('Facade/HandsSettings.swift'), /environment\["TATWO2_HANDS|environment\["TATWO_HANDS/);
  assert.match(swift('Facade/HandsTools.swift'), /ThreadGoalRules\.add\(&\$0, title: "〔ChatGPT〕" \+ clean, userWords: nil, proposed: true\)/);
});

test('V14 memory: formal memory readable minus "not for ChatGPT", inbox fields written by the App, list only your own', () => {
  assert.match(memory, /static let inboxFolder = "chatgpt-inbox"/);
  // W183 R1b：結構化解析（行尾註解、引號都認；看不懂的寫法、不認得的值一律當作不給／未驗證）。
  assert.match(memory, /static func fieldValues\(_ lines: \[String\], keys: Set<String>\) -> \[FieldValue\]/);
  assert.match(memory, /return hiddenWords\.contains\(word\) \|\| !visibleWords\.contains\(word\)/);
  assert.match(memory, /guard case \.text\(let text\) = value else \{ return true \}/);
  assert.match(memory, /return !\["true", "yes", "on"\]\.contains\(text\.lowercased\(\)\)/);
  assert.doesNotMatch(memory, /\(hidden\|no\|false\|off\|deny\|不給\)\["'\]\?\\s\*\$/, 'no line regex that breaks on trailing comments');
  assert.match(memory, /var source = "chatgpt"\s*\n\s*var verified = false/);
  assert.match(memory, /HandsMemory\.InboxEntry\(grantID: grant\.grantID, createdAt: now, workspaceID: workspace\?\.id\.uuidString,/);
  assert.match(memory, /entries\(\)\.filter \{ !HandsMemory\.hiddenFromChatGPT\(\$0\.file\) \}/);
  assert.match(memory, /guard !HandsMemory\.hiddenFromChatGPT\(entry\.file\) else \{ throw HandsToolError\.invalid\("memory_not_found"\) \}/);
  assert.match(memory, /"verified": HandsMemory\.verified\(entry\.file\)/);
  assert.match(memory, /static let maxPerGrant = 200/);
  assert.match(memory, /TatwoMemoryStore\.containsSecret/);
});

test('Rooms: per-project root, no engine, rows per call, watchdog excluded, composer and redo locked, selftest wired', () => {
  const engine = swift('Facade/ChatLiveEngine.swift');
  assert.match(engine, /static let handsEngine = "chatgpt-hands"/);
  const send = between(engine, '@discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind = .claude', 'var plan: TatwoPlanArtifactV1?');
  assert.match(send, /if threadRecord\(threadID\)\?\.engine == Self\.handsEngine \{/);
  const root = between(engine, 'func handsRootThread(', 'func handsInsertWorkspace(');
  assert.match(root, /projectID: UUID\? = nil/);
  assert.match(root, /\$0\.projectID == project/);
  assert.doesNotMatch(root, /selectedThreadID|ensureSidecar|\.send\(/);
  assert.match(swift('Facade/DispatchWatchdog.swift'), /guard t\.engine != ChatLiveEngine\.handsEngine else \{ continue \}/);
  assert.match(swift('Facade/ChatPageModel.swift'), /var canSend: Bool \{\s*if selectedRemote == nil && localConversationReadOnlyNotice != nil \{ return false \}\s*if isSelectedHandsThread \{ return false \}/);
  assert.match(service, /status: "running-command\|\\\(name\)"/);
  assert.match(service, /"〔外部資料・ChatGPT・\\\(grant\)〕\\\(tool\)：/);
  assert.match(service, /let target = rootThread\(projectID: landing\.projectID\)/);
  assert.match(rooms, /let parent = rootThread\(projectID: project\.id\)/);
  const selftest = swift('SelfTest.swift');
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w183hands"[\s\S]{0,200}HandsAcceptance\.run\(\)/);
  const acceptance = swift('Facade/HandsAcceptance.swift');
  for (const label of ['身分（真的連線）：它開的子行程是其他程式', '配對：App 沒開配對窗口', '確認卡：交易編號', '配對：錯碼 5 次整筆作廢',
    '配對：窗口 10 分鐘到期', 'token：舊的 refresh 再被用＝撤銷該 grant', '限流：App 端每 client', '等級：grant 核准時是 L1', '開關：關掉＝撤銷全部 grant',
    '匯出：工作區只有目前版本', '匯出：正本的 hook、filter、fsmonitor 一個都沒跑', '沙盒：正本（含 .git 設定、物件、歷史）一律讀不到',
    '沙盒：工具鏈不開 Homebrew', '沙盒：巢狀 .git、AGENTS.md', '輸出證據：沙盒裡改不了', 'request_id：同 id 同參數回原結果', '跨 grant：',
    '收件匣：source／verified／grant_id／時間由 App 寫', '交件：還有別的程式開著工作區', '交件：手腳沙盒裡 setsid 脫離、cwd 在工作區的行程被收掉',
    '交件：候選 commit 父親＝base_sha', '交件：正本的 hook、filter、fsmonitor 一個都沒跑', '對照組：沒加固的 git update-ref',
    '審查：施工卡 diff 用固定候選 SHA', '審查：重新交件＝舊審查作廢', '撤銷一個 grant', '看門狗：ChatGPT 的房間不收',
    // W183 R1b
    '合併：會寫到有 git filter 的檔', '合併：git 設定會讀專案工作樹裡的檔', '合併：設了 merge driver', '合併：只改沒有 filter 的檔＝合併成功',
    '對照組：沒加固的 git archive 會跑正本的 smudge filter', '對照組：沒加固的 git status 會跑正本的 fsmonitor', '對照組：沒加固的 git merge-tree 會跑 merge driver',
    '匯出：影子 gitdir 的設定沒有 filter', '交件檢查：git 輸出被截斷＝拒絕', '遮蔽：專案裡的私鑰從中間那行讀也遮住', '輸出證據：秘密在寫進輸出區之前就遮好',
    '遮蔽：工作區裡的私鑰從中間那行讀也遮住', '記憶：行尾有註解的', 'request_id：記憶後來標成不給 ChatGPT', '交件：job_start 也拿工作區的鎖',
    '交件：列舉行程失敗＝無法判定', '交件：保護項目跟開的時候不一樣', '交件：認不出手腳行程（探針不在）', '沙盒：有指示文件的資料夾搬不走',
    '磁碟：快滿了', '磁碟：寫檔也算進工作區上限', '磁碟：指令跑到一半磁碟快滿', '輸出區：超過 7 天的輸出清掉', '撤銷：撤銷後才輪到啟動的工作',
    // W183 R10：本機允許清單不再是閘門（全部可見）——「後來縮小的授權」改用 Coder 裡拿掉那個專案驗（守的一樣：重送不繞過後來縮小的授權）。
    'request_id：專案後來不在了（Coder 裡拿掉）', '撤銷：存不了檔也不會讓舊授權復活', 'request_id：同一個過期的鍵同時被重送', 'token：用過的 refresh 紀錄滿了就停止換新']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.doesNotMatch(acceptance, /cloudflared|startTunnel|ChatGPTHandsService/, 'selftest never opens a tunnel or starts the gateway');
});

// ---------- 檔案小幫手（在沙盒外直接跑 node；沙盒本身由 App 自測驗） ----------

function scratch() {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183-fsop-')));
}
function fsop(request) {
  const result = spawnSync(process.execPath, [fsopPath], { input: JSON.stringify(request), encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
const sha = text => crypto.createHash('sha256').update(text).digest('hex');

test('fsop.mjs read/list/search: line numbers, sha256, fixed order, cursor, complete, path:line:col with context', () => {
  const source = read('Engines/chatgpt-hands/fsop.mjs');
  for (const match of source.matchAll(/^import .* from '([^']+)';$/gm)) assert.ok(match[1].startsWith('node:'), match[1]);
  const root = scratch();
  fs.mkdirSync(path.join(root, 'src'));
  fs.writeFileSync(path.join(root, 'src/a.txt'), 'one\ntwo\nthree\n');
  const reply = fsop({ op: 'read', root, path: 'src/a.txt', offset_line: 2, limit_lines: 1 });
  assert.equal(reply.lines, '2\ttwo\n');
  assert.equal(reply.total_lines, 3);
  assert.equal(reply.sha256, sha('one\ntwo\nthree\n'));
  assert.equal(reply.truncated, true);
  for (let index = 0; index < 700; index += 1) fs.writeFileSync(path.join(root, `f${String(index).padStart(3, '0')}.txt`), 'x\n');
  const firstPage = fsop({ op: 'list', root, path: '' });
  assert.equal(firstPage.items.length, 500);
  assert.equal(firstPage.complete, false);
  const secondPage = fsop({ op: 'list', root, path: '', cursor: firstPage.cursor });
  assert.equal(secondPage.complete, true);
  const names = [...firstPage.items, ...secondPage.items].map(item => item.path);
  assert.deepEqual(names, [...names].sort());
  const found = fsop({ op: 'search', root, path: 'src', query: 'two' });
  assert.equal(found.items[0].location, 'src/a.txt:2:1');
  assert.deepEqual(found.items[0].before, ['1: one']);
  assert.deepEqual(found.items[0].after, ['3: three']);
  assert.equal(found.complete, true);
});

test('fsop.mjs writes: protected at any depth and case, optimistic locks, symlinks and hard links refused, atomic', () => {
  const root = scratch();
  fs.mkdirSync(path.join(root, 'src'));
  fs.writeFileSync(path.join(root, 'src/a.txt'), 'one\n');
  const outside = path.join(scratch(), 'secret.txt');
  fs.writeFileSync(outside, 'CANARY-outside');
  fs.symlinkSync(outside, path.join(root, 'link'));
  fs.writeFileSync(path.join(root, 'src/b.txt'), 'linked\n');
  fs.linkSync(path.join(root, 'src/b.txt'), path.join(root, 'hard'));
  for (const target of ['.git/config', 'deep/.claude/settings.json', 'x/.mcp.json', 'AGENTS.md', 'agents.md', 'sub/Claude.md', 'GEMINI.md',
    '.gitattributes', '.GITMODULES', '.cursorrules', '.windsurfrules', '.github/copilot-instructions.md', 'a/.github/Copilot-Instructions.md',
    '.github', '.cursor/rules', '.vscode/tasks.json', '.codex/x', '.agents/x', '.tatwo2/x']) {
    const reply = fsop({ op: 'write', root, path: target, content: 'x', create_only: true });
    assert.equal(reply.error, 'protected_path', target);
  }
  assert.equal(fsop({ op: 'write', root, path: '.github/workflows/ci.yml', content: 'x', create_only: true }).error, 'protected_path',
    'creating the .github folder itself is refused');
  for (const [request, code] of [
    [{ op: 'read', root, path: '../x' }, 'path_escapes_workspace'],
    [{ op: 'read', root, path: '/etc/hosts' }, 'path_must_be_relative'],
    [{ op: 'read', root, path: 'link' }, 'symlink_refused'],
    [{ op: 'read', root, path: 'hard' }, 'hardlink_refused'],
    [{ op: 'write', root, path: 'src/a.txt', content: 'x', create_only: true }, 'file_exists'],
    [{ op: 'write', root, path: 'src/a.txt', content: 'x', expected_sha256: '0'.repeat(64) }, 'file_changed'],
    [{ op: 'write', root, path: 'src/c.txt', content: 'x' }, 'give exactly one of create_only or expected_sha256'],
    [{ op: 'edit', root, path: 'src/a.txt', old_string: 'one', new_string: 'two' }, 'expected_sha256_invalid'],
    [{ op: 'write', root: root + '/../', path: 'a', content: 'x', create_only: true }, 'root_not_canonical'],
    [{ op: 'nope', root }, 'unknown_op'],
  ]) {
    const reply = fsop(request);
    assert.equal(reply.ok, false, JSON.stringify(request));
    assert.equal(reply.error, code, JSON.stringify(reply));
  }
  assert.equal(fs.readFileSync(outside, 'utf8'), 'CANARY-outside');
  const written = fsop({ op: 'write', root, path: 'src/a.txt', content: 'uno\n', expected_sha256: sha('one\n') });
  assert.equal(written.sha256, sha('uno\n'));
  const edited = fsop({ op: 'edit', root, path: 'src/a.txt', old_string: 'uno', new_string: 'one', expected_sha256: written.sha256 });
  assert.equal(edited.replacements, 1);
  assert.equal(fsop({ op: 'write', root, path: 'new/deep/file.txt', content: 'hi\n', create_only: true }).created, true);
  assert.deepEqual(fs.readdirSync(path.join(root, 'new/deep')), ['file.txt'], 'no temp files left behind');
});

test('fsop.mjs apply_patch: update, add, delete, move; context must match; all-or-nothing even when a write fails midway', () => {
  const root = scratch();
  fs.mkdirSync(path.join(root, 'src'));
  fs.writeFileSync(path.join(root, 'src/app.js'), 'function a() {\n  return 1;\n}\n\nfunction b() {\n  return 2;\n}\n');
  fs.writeFileSync(path.join(root, 'old.txt'), 'bye\n');
  fs.writeFileSync(path.join(root, 'move.txt'), 'm\n');
  const patch = ['*** Begin Patch', '*** Update File: src/app.js', '@@ function b() {', '-  return 2;', '+  return 3;', '*** Add File: docs/new.md', '+# New',
    '*** Delete File: old.txt', '*** Update File: move.txt', '*** Move to: moved/move.txt', '@@', '-m', '+moved', '*** End Patch'].join('\n');
  const reply = fsop({ op: 'apply_patch', root, patch });
  assert.equal(reply.ok, true, JSON.stringify(reply));
  assert.match(fs.readFileSync(path.join(root, 'src/app.js'), 'utf8'), /return 1;[\s\S]*return 3;/);
  assert.equal(fs.readFileSync(path.join(root, 'docs/new.md'), 'utf8'), '# New\n');
  assert.ok(!fs.existsSync(path.join(root, 'old.txt')));
  assert.equal(fs.readFileSync(path.join(root, 'moved/move.txt'), 'utf8'), 'moved\n');
  const before = fs.readFileSync(path.join(root, 'src/app.js'), 'utf8');
  const bad = fsop({ op: 'apply_patch', root, patch: '*** Begin Patch\n*** Add File: ok.txt\n+x\n*** Update File: src/app.js\n@@\n-not there\n+y\n*** End Patch' });
  assert.equal(bad.error, 'patch_context_not_found');
  assert.ok(!fs.existsSync(path.join(root, 'ok.txt')), 'nothing written when any part fails');
  assert.equal(fs.readFileSync(path.join(root, 'src/app.js'), 'utf8'), before);
  // 寫到一半才失敗（第二個檔所在的資料夾唯讀）：第一個檔要還原。
  fs.mkdirSync(path.join(root, 'locked'));
  fs.writeFileSync(path.join(root, 'locked/l.txt'), 'l\n');
  fs.chmodSync(path.join(root, 'locked'), 0o555);
  try {
    const midway = fsop({ op: 'apply_patch', root, patch: '*** Begin Patch\n*** Update File: src/app.js\n@@\n-  return 1;\n+  return 9;\n*** Update File: locked/l.txt\n@@\n-l\n+L\n*** End Patch' });
    assert.equal(midway.ok, false, JSON.stringify(midway));
    assert.match(String(midway.detail ?? ''), /nothing was changed/);
    assert.equal(fs.readFileSync(path.join(root, 'src/app.js'), 'utf8'), before, 'first file restored');
  } finally { fs.chmodSync(path.join(root, 'locked'), 0o755); }
  assert.equal(fsop({ op: 'apply_patch', root, patch: '*** Begin Patch\n*** Add File: .git/hooks/x\n+x\n*** End Patch' }).error, 'protected_path');
  assert.equal(fsop({ op: 'apply_patch', root, patch: '*** Begin Patch\n*** Delete File: AGENTS.md\n*** End Patch' }).error, 'protected_path');
  assert.equal(fsop({ op: 'apply_patch', root, patch: 'no markers' }).error, 'patch_missing_markers');
});

test('fsop.mjs R1b: secret lines masked with whole-file context; search never matches them; rollback is verified and never claims nothing changed', async () => {
  const { secretLineMask, rollback, MASKED_LINE } = await import(fsopPath);
  // 標記在執行時拼（原始碼裡不放完整的私鑰標記，公開倉掃描才不會誤判）。
  const marker = (kind, type = '') => `${'-'.repeat(5)}${kind} ${type}PRIVATE KEY${'-'.repeat(5)}`;
  const key = [marker('BEGIN', 'RSA '), 'MIIEowIBAAKCAQEA' + 'Ab1'.repeat(16), 'tail==', marker('END', 'RSA '), 'after',
    'Authorization: Bearer', 'abcdefghijkl rest'];
  assert.deepEqual(secretLineMask(key), ['all', 'all', 'all', 'all', null, null, 'first']);
  assert.deepEqual(secretLineMask(['Ab1'.repeat(22), 'short+/==', 'normal words']), ['all', 'all', null], 'key body without BEGIN');
  assert.deepEqual(secretLineMask(['e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855']), [null], 'hex digests stay readable');
  const root = scratch();
  const secret = 'Zz9' + crypto.randomBytes(24).toString('hex').toUpperCase() + 'q';
  const material = [marker('BEGIN', 'OPENSSH '), secret + 'Ab1'.repeat(8), 'Qq' + secret,
    marker('END', 'OPENSSH '), 'Authorization: Bearer', secret.toLowerCase() + ' rest'].join('\n') + '\n';
  // W183 R10 底線 A：名字像金鑰的檔（k.pem）整個讀不到、列不出、搜不到；遮蔽照樣要守——同一段貼在名字不像金鑰的檔（pasted.txt）裡。
  fs.writeFileSync(path.join(root, 'k.pem'), material);
  fs.writeFileSync(path.join(root, 'pasted.txt'), material);
  assert.equal(fsop({ op: 'read', root, path: 'k.pem', offset_line: 3, limit_lines: 1 }).error, 'secret_file_refused');
  const listed = fsop({ op: 'list', root, path: '' }).items.map((item) => item.path);
  assert.ok(!listed.includes('k.pem') && listed.includes('pasted.txt'), 'the key file is not even listed (the other one is)');
  const middle = fsop({ op: 'read', root, path: 'pasted.txt', offset_line: 3, limit_lines: 1 });
  assert.equal(middle.lines, `3\t${MASKED_LINE}\n`, 'a page that starts inside the key is still masked');
  const tokenLine = fsop({ op: 'read', root, path: 'pasted.txt', offset_line: 6, limit_lines: 1 });
  assert.equal(tokenLine.lines, '6\t[已遮蔽] rest\n', 'Bearer on the previous line still masks the token');
  assert.equal(fsop({ op: 'search', root, path: '', query: secret.slice(4, 20) }).items.length, 0, 'masked lines are never matched');
  assert.equal(fsop({ op: 'search', root, path: '', query: secret.slice(4, 20).toLowerCase(), case_sensitive: false }).items.length, 0);
  // 刪掉 3 MiB 的檔之後第二步失敗：以前還原上限只有 2 MiB（吞掉錯誤還說什麼都沒改）；現在整個放回去並驗過。
  fs.writeFileSync(path.join(root, 'big.txt'), 'a'.repeat(3 * 1024 * 1024));
  fs.mkdirSync(path.join(root, 'ro'));
  fs.chmodSync(path.join(root, 'ro'), 0o555);
  try {
    const failed = fsop({ op: 'apply_patch', root, patch: '*** Begin Patch\n*** Delete File: big.txt\n*** Add File: ro/new.txt\n+x\n*** End Patch' });
    assert.equal(failed.ok, false);
    assert.match(String(failed.detail), /nothing was changed/);
    assert.equal(fs.statSync(path.join(root, 'big.txt')).size, 3 * 1024 * 1024, 'the 3 MiB file is back');
    // 還原本身失敗：列出還原不了的檔（呼叫端回 patch_partially_applied，不說什麼都沒改）。
    assert.deepEqual(rollback(root, [{ kind: 'write', parts: ['ro', 'x.txt'], created: false, backup: { data: Buffer.from('b'), mode: 0o644 } }]), ['ro/x.txt']);
  } finally { fs.chmodSync(path.join(root, 'ro'), 0o755); }
  const source = read('Engines/chatgpt-hands/fsop.mjs');
  assert.match(source, /fail\('patch_partially_applied'/);
  assert.match(source, /if \(mask\[index\] === 'all'\) continue;/);
});

test('W183 files stay private-safe: no private domain, host or account literals in the new sources', () => {
  const files = ['Facade/HandsContract.swift', 'Facade/HandsSettings.swift', 'Facade/HandsAuth.swift', 'Facade/HandsSandbox.swift',
    'Facade/HandsService.swift', 'Facade/HandsTools.swift', 'Facade/HandsRooms.swift', 'Facade/HandsState.swift', 'Facade/HandsAcceptance.swift',
    'Facade/HandsJobs.swift', 'Facade/HandsMemory.swift', 'Facade/HandsReview.swift', 'Facade/HandsSecrets.swift']
    .map(swift).concat(read('Engines/chatgpt-hands/fsop.mjs'));
  for (const text of files) {
    // W183 R6c 審查：/System/Volumes/Data 是 macOS 的系統路徑（沙盒整個拒），不是使用者的卷名。
    assert.doesNotMatch(text, /\.local\b|\/Users\/[a-z]|(?<!\/System)\/Volumes\/[A-Za-z]|trycloudflare|cfargotunnel/i);
  }
});
