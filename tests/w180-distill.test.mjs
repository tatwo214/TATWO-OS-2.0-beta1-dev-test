import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { resolveBinary } from './helpers/app-binary.mjs';

// W180 E4：/蒸餾 重設計——session 做完整理成技能（預設）或清單、SOP、GBrain 頁；預覽後確認才寫，
// 寫入一律在主設備、同名先封存可還原；skillet 不再是去處；遠端（副設備看主設備的 session）走已配對設備通道。
const read = file => fs.readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
const swift = 'App/Sources/Tatwo2/';

test('W180 E4 guidance: /蒸餾 turns a finished session into reusable material, not GBrain-only', () => {
  const upstream = read('docs/os-upstream.md');
  assert.equal(upstream, read(swift + 'Resources/os-upstream.md'));
  const line = upstream.split('\n').find(row => row.startsWith('- `/蒸餾`'));
  assert.match(line, /整理成可重用的東西/);
  assert.match(line, /預設技能 SKILL\.md/);
  assert.match(line, /寫不寫、寫到哪由使用者按鈕決定/);
  assert.doesNotMatch(upstream, /蒸餾進 GBrain/);
  const template = read(swift + 'Resources/os.md');
  assert.doesNotMatch(template, /寫經驗進 GBrain|選 GBrain、skillet 或兩者|副設備選 skillet/);
  assert.match(template, /`\/蒸餾` 把做完的 session 整理成技能或其他可重用的東西/);
  assert.match(template, /預設寫成技能（SKILL\.md）/);
  assert.match(template, /不是記憶入口/);
  assert.match(template, /寫入一律在主設備執行，副設備交給主設備寫/);
  assert.doesNotMatch(template, /\bmini\b|\bMacBook\b|\/Users\/|\/Volumes\//i);
  const model = read(swift + 'Facade/ChatPageModel.swift');
  assert.match(model, /title: "\/蒸餾 — 把這條對話整理成技能"/);
  assert.match(model, /subtitle: "預設寫成技能；也可選清單、SOP、GBrain，確認才寫入"/);
  assert.doesNotMatch(model, /選 GBrain／skillet，按送出才寫入/);
  const overview = read(swift + 'New/OSOverviewPage.swift');
  assert.doesNotMatch(overview, /蒸餾由 Claude/);
  assert.match(overview, /\/蒸餾：做完的對話整理成技能，確認才寫入/);
  // 助理說明書（W179 已改）與這裡同一個說法。
  assert.ok(read(swift + 'Resources/tatwo-assistant.md').includes('把它整理成技能或其他可以重用的東西'));
});

test('W180 E4 skillet is never a destination; memory is not an output kind; reserved names', () => {
  const sources = ['Facade/DistillCanvas.swift', 'Facade/DistillWriter.swift', 'Facade/DistillHost.swift',
    'Facade/ChatPageModel+Distill.swift', 'Chat/DistillPlanActions.swift'].map(file => read(swift + file));
  for (const source of sources) {
    assert.doesNotMatch(source, /writeFromDevice\(id: "skillet"|OSDocuments\.(read|write)\w*\(id: "skillet"|writeSkillet|proposeSkillet|inbox_receive/);
    assert.doesNotMatch(source, /替換入口 skillet\.md 全文|UserMemoryStore/);
  }
  const kinds = read(swift + 'Chat/DistillSubmission.swift');
  assert.match(kinds, /enum DistillOutputKind: String, Codable, CaseIterable, Sendable \{\n    case skill, checklist, sop, gbrain\n/);
  assert.doesNotMatch(kinds, /case memory|"記憶"/);
  // tests/w29b 會把這兩個檔單獨編譯：只能依賴 Foundation。
  assert.doesNotMatch(kinds, /^import (?!Foundation)/m);
  assert.match(read(swift + 'Chat/TatwoPlanArtifact.swift'), /decodeIfPresent\(DistillOutputKind\.self, forKey: \.distillOutput\)/);
  const writer = read(swift + 'Facade/DistillWriter.swift');
  assert.match(writer, /reservedSkillNames: Set<String> = \["tatwo-ultrawork", "skillet"\]/);
  assert.match(writer, /DistillWriterRoots\(skills: ManagedSkills\.defaultRoot\(\), entry: TatwoEntry\(\)\.root\)/);
  assert.match(writer, /appendingPathComponent\("蒸餾", isDirectory: true\)/);
  const canvas = read(swift + 'Facade/DistillCanvas.swift');
  assert.match(canvas, /EngineRuleAudit\.audit\(text, kind: \.skill\)/);
});

test('W180 E4 drafting: default skill rules, tatwo-distill fence, /蒸餾 translated for the engine', () => {
  const plan = read(swift + 'Facade/ChatLiveEngine+Plan.swift');
  const rules = plan.slice(plan.indexOf('static func distillDiscussionRules'), plan.indexOf('    private func planURL('));
  assert.match(rules, /預設整理成技能 SKILL\.md/);
  assert.match(rules, /```tatwo-distill/);
  assert.match(rules, /只有 App 畫布的「確認寫入」按鈕能寫/);
  assert.doesNotMatch(rules, /寫進 GBrain|記憶|skillet 或兩者/);
  assert.match(plan, /guard plan\.distillSubmission == nil else \{ return nil \}/);
  assert.match(plan, /DistillCanvas\.draft\(from: reply\.text, legacy: plan\.distillOutput == nil\)/);
  const engine = read(swift + 'Facade/ChatLiveEngine.swift');
  const text = engine.slice(engine.indexOf('static func engineText('), engine.indexOf('"/plg" else { return text }'));
  assert.match(text, /DistillCanvas\.argument\(in: trimmed\)/);
  assert.match(text, /使用者下了 OS 指令 \/蒸餾/);
});

test('W180 E4 canvas actions: glass chips, confirm only on a current preview, boundary saved before any write', () => {
  const actions = read(swift + 'Chat/DistillPlanActions.swift');
  assert.doesNotMatch(actions, /borderedProminent|buttonStyle\(\.bordered\)|Toggle\(|\.tint\(\.blue\)|Color\.blue|alert\(|confirmationDialog/);
  assert.match(actions, /chatGlassChip/);
  assert.match(actions, /"確認寫入"[\s\S]*?\.disabled\(!previewCurrent/);
  assert.match(actions, /guard previewCurrent, let plan = preview/);
  for (const label of ['"預覽寫入"', '"返回修改"', '"還原"', '"整理成"']) assert.ok(actions.includes(label), label);
  assert.match(actions, /onChange\(of: content\) \{ _, _ in preview = nil \}/);
  assert.match(actions, /onChange\(of: output\) \{ _, _ in preview = nil \}/);
  const host = read(swift + 'Facade/DistillHost.swift');
  const apply = host.slice(host.indexOf('guard plan.distillSubmission == nil else { throw failure("這張畫布已經寫入過'),
    host.indexOf('        case .restore:\n            // 預設還原這張畫布的寫入'));
  assert.ok(apply.length > 100, 'apply branch');
  assert.ok(apply.indexOf('plan.distillSubmission = submission') < apply.indexOf('try engine.savePlanArtifact(plan)'));
  assert.ok(apply.indexOf('try engine.savePlanArtifact(plan)') < apply.indexOf('job(.apply'));
  assert.match(apply, /guard fresh == request\.expected/);
  const writer = read(swift + 'Facade/DistillWriter.swift');
  const applyFn = writer.slice(writer.indexOf('private static func apply('), writer.indexOf('private static func restore('));
  assert.ok(applyFn.indexOf('被改過') < applyFn.indexOf('makeArchive'), 'base re-check before archive');
  assert.ok(applyFn.indexOf('makeArchive') < applyFn.indexOf('data.write(to: url, options: .atomic)'), 'archive before write');
  assert.match(applyFn, /guard try Data\(contentsOf: url\) == data/);
  assert.match(writer, /lock\.lock\(\); defer \{ lock\.unlock\(\) \}/);
  const panel = read(swift + 'Chat/ChatPage+Plan.swift');
  assert.match(panel, /DistillPlanActions\(artifact: artifact, isDisabled: isEditing \|\| isWriting,\s*actions: distillActions\)/);
  assert.match(read(swift + 'Chat/ChatPage.swift'), /distillActions: model\.distillCanvasActions/);
});

test('W180 E4 remote distill: paired-device channel only, SSH callers only, no command or computer rights', () => {
  const bridge = read(swift + 'Facade/OSAgentBridge.swift');
  const ssh = bridge.match(/static let sshForwardMethods: Set<String> = \[([\s\S]*?)\]/)[1];
  for (const method of ['distill_open', 'distill_get', 'distill_edit', 'distill_write']) assert.ok(ssh.includes(`"${method}"`), method);
  assert.doesNotMatch(ssh, /"run_background"|"computer_|"cli_|"run_command"|"app_terminate/);
  const untrusted = bridge.match(/static let untrustedCallerMethods: Set<String> = \[([\s\S]*?)\]/)[1];
  assert.doesNotMatch(untrusted, /distill_/);
  assert.match(bridge, /if DistillRemoteRequest\.methods\.contains\(method\) \{ return caller == \.ssh \}/);
  const handler = bridge.slice(bridge.indexOf('case "distill_open", "distill_get", "distill_edit", "distill_write":'),
    bridge.indexOf('case "new_thread":'));
  assert.match(handler, /DistillRemoteRequest\.parse\(method: method, params: params\)/);
  assert.match(handler, /model\.distillRemoteBegin\(request\)/);
  assert.match(handler, /DistillWriter\.perform\(job\)/);
  assert.match(handler, /model\.distillRemoteFinish\(job, outcome\)/);
  assert.doesNotMatch(handler, /Process\(|run_background|computer|live\.send|DeviceDispatch/);
  const host = read(swift + 'Facade/DistillHost.swift');
  assert.match(host, /plan\.kind == "distill" else \{ return nil \}/);
  assert.match(host, /Set\(params\.keys\)\.isSubset\(of: allowed\)/);
  const remote = read(swift + 'Facade/RemoteLiveEngine.swift');
  assert.match(remote, /func distillCall\(_ method: String/);
  assert.match(remote, /guard DistillRemoteRequest\.methods\.contains\(method\)/);
  const model = read(swift + 'Facade/ChatPageModel.swift');
  assert.match(model, /if DistillCanvas\.argument\(in: prompt\) != nil, selectedRemote != nil \{/);
  assert.match(model, /guard !rejectRemoteWrite\("\/plan"\)/);
  assert.match(model, /if selectedRemote != nil \{ return saveRemoteDistillText\(text\) \}/);
  assert.match(model, /if selectedRemote != nil \{ refreshRemoteDistillCanvas\(\); return \}/);
  const routing = read(swift + 'Facade/ChatPageModel+Distill.swift');
  assert.match(routing, /return \.blocked\("主設備連不上，連上後再寫入"\)/);
  // 私訊框照樣擋 /蒸餾（Coder 專用）。
  assert.match(model, /"\/蒸餾"\]\.contains\(first\)/);
});

test('W180 E4 review fixes: writes stay on the primary, off the serial bridge queue, bound to their own canvas', () => {
  const bridge = read(swift + 'Facade/OSAgentBridge.swift');
  // distill_write 不在一次只處理一個請求的 handlerQueue 上跑；寫入在背景，最多等幾秒就先回「寫入中」。
  const handle = bridge.slice(bridge.indexOf('    private func handle(clientFD:'), bridge.indexOf('    private func write(_ value: [String: Any]'));
  const lane = handle.slice(handle.indexOf('if method == "distill_write" {'), handle.indexOf('        let response: [String: Any]'));
  assert.ok(lane.includes('releaseOnReturn = false') && lane.includes('distillQueue.async'), 'distill_write has its own lane');
  assert.match(bridge, /private let distillQueue = DispatchQueue\(label: "ai\.tatwo\.tatwo2\.os-agent\.distill", qos: \.userInitiated, attributes: \.concurrent\)/);
  const handler = bridge.slice(bridge.indexOf('case "distill_open", "distill_get", "distill_edit", "distill_write":'),
    bridge.indexOf('case "new_thread":'));
  assert.match(handler, /distillJobQueue\.async/);
  assert.match(handler, /box\.wait\(DistillWire\.replyWait\)/);
  assert.match(handler, /status: "writing"/);
  // 錯誤轉字串（String(describing:)）要是白話原因。
  assert.match(read(swift + 'Facade/DistillCanvas.swift'), /struct Failure: LocalizedError, CustomStringConvertible \{[\s\S]*?var description: String \{ reason \}/);
  const routing = read(swift + 'Facade/ChatPageModel+Distill.swift');
  assert.match(routing, /detail\.hasPrefix\("remote_access_disabled"\)/);
  // 收端是副設備就不寫；發端只把主設備上的 session 交那台寫。
  assert.match(routing, /request\.method == "distill_write", request\.action != \.status, distillPrimary\(\) != nil/);
  assert.match(routing, /guard isPrimary else \{ return \.blocked\(/);
  // 那台先回「寫入中」或連線斷掉：用 status 查到有定論，不重送。
  assert.match(routing, /func awaitDistillResult\(/);
  assert.match(routing, /action: \.status/);
  // 遠端 session 有更新時（RemoteDeviceSession.onUpdate）畫布跟上。
  const model = read(swift + 'Facade/ChatPageModel.swift');
  assert.match(model, /session\.onUpdate = \{[\s\S]*?self\.distillRemoteSessionUpdated\(deviceID: session\.device\.id\)/);
  assert.match(model, /guard openLocalDistillCanvas\(id, argument:/);
  // 主設備送給引擎時附上該討論串畫布的規則（遠端 send_message 也走 live.send）。
  const engine = read(swift + 'Facade/ChatLiveEngine.swift');
  const send = engine.slice(engine.indexOf('@discardableResult func send(threadID: UUID'), engine.indexOf('func savePastedAttachment('));
  assert.match(send, /plan = try loadPlanArtifact\(threadID\)/);
  assert.match(send, /let planBriefing = planContext\(plan, userText: t\)/);
  // 還原只認這次寫入：同一張畫布、同一次確認寫入；封存紀錄的路徑再驗一次；GBrain 沒放回就不記「已還原」。
  const writer = read(swift + 'Facade/DistillWriter.swift');
  const restore = writer.slice(writer.indexOf('private static func restore('), writer.indexOf('static func readManifest('));
  assert.match(restore, /manifest\.planID == planID, manifest\.threadID == job\.threadID/);
  assert.match(restore, /manifest\.submissionID == submissionID/);
  assert.match(restore, /allowedFile\(entry\.path, output: manifest\.output, roots: job\.roots\)/);
  assert.match(restore, /GBrain 不可用；沒有還原/);
  assert.ok(restore.indexOf('GBrain 不可用；沒有還原') < restore.indexOf('manifest.restoredAt = now'), 'preflight before marking restored');
  assert.match(restore, /DistillGBrainClient\.restore\(slug: slug, archived: page, writtenSHA: entry\.newSHA/);
  // 開新畫布：寫入中不蓋、已寫入的留在歷史；遠端不蓋進行中的別種畫布。
  const host = read(swift + 'Facade/DistillHost.swift');
  assert.match(host, /all\.contains\(where: \{ inFlight\.contains\(\$0\.id\) \}\)/);
  assert.match(host, /plan\.distillEarlier = kept\.isEmpty \? nil : kept/);
  assert.match(host, /else if remote && !finishedOtherCanvas\(existing, engine: engine\)/);
  // 技能名稱照 Agent Skills 規範。
  const canvas = read(swift + 'Facade/DistillCanvas.swift');
  assert.match(canvas, /\^\[a-z0-9\]\+\(-\[a-z0-9\]\+\)\*\$/);
  assert.match(canvas, /name\.contains\("anthropic"\) \|\| name\.contains\("claude"\)/);
  assert.match(canvas, /description 最多 1024 個字/);
  assert.match(canvas, /name: <技能資料夾名：小寫英文、數字和 -，64 字內>/);
});

test('W180 E4 production Swift acceptance: TATWO2_SELFTEST=w180distill', { timeout: 300_000 }, () => {
  const binary = resolveBinary();
  // 整批驗收一定帶得到建好的 App（staging 建置快取）；找不到就失敗，不跳過。
  assert.ok(binary && fs.existsSync(binary), 'Set TATWO2_TEST_BINARY (or run inside the staging build worktree); never skip.');
  const root = fs.realpathSync(fs.mkdtempSync(path.join(tmpdir(), 'w180d-')));
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e/codex', 'e/claude', 'os', 'docs']) fs.mkdirSync(at(name), { recursive: true });
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'), TATWO2_LIVE_ROOT: at('l'),
    TATWO2_ENGINES_ROOT: at('e'), CODEX_HOME: at('e/codex'), TATWO2_CODEX_SOURCE_HOME: at('e/codex'),
    CLAUDE_CONFIG_DIR: at('e/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('e/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'), TATWO2_OS_ROOT: at('os'),
    TATWO2_DOCS_ROOT: at('docs'), TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'),
    TATWO2_SKILLET_PATH: at('os/skillet.md'), TATWO2_SELFTEST: 'w180distill',
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 280_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output.split('\n').filter(line => line.startsWith('W180DISTILL')).join('\n') || output.slice(-4000));
  assert.match(output, /W180DISTILL SUMMARY passed=\d+ failures=0/);
  for (const name of [
    'legacy-json-reads-back', 'nil-output-is-skill', 'rules-default-skill', 'ai-draft-skill-exact', 'skill-name-rejected',
    'skill-audit-blocks-secret', 'legacy-five-heading-still-parses', 'engine-text-distill-translated',
    'skill-new-write-byte-exact', 'skill-replace-archives-first', 'restore-puts-original-back', 'stale-base-no-overwrite',
    'checklist-to-note', 'secondary-no-local-write', 'skillet-never-touched', 'edit-invalidates-preview',
    'repeat-submission-rejected', 'submission-survives-reopen-no-rewrite', 'remote-open-creates-primary-canvas',
    'remote-reply-updates-primary-canvas', 'remote-write-lands-on-primary', 'remote-other-plan-kinds-still-rejected',
    'remote-methods-ssh-only', 'secondary-offline-queued-not-sent', 'written-skill-appears-in-dollar-list',   // W182 R5：離線改排隊
    // W180 E4 審查修正
    'skill-description-rules', 'bridge-error-text-is-plain', 'unpaired-primary-refuses-remote-distill', 'open-refused-while-writing', 'gbrain-adapter-error-not-written',
    'gbrain-unreadable-page-not-written', 'gbrain-restore-needs-gbrain', 'gbrain-new-page-restore-not-marked',
    'bridge-error-reaches-secondary-as-plain-text', 'secondary-receiver-refuses-writes', 'threadless-restore-bound-to-its-own-write',
    'restore-revalidates-manifest-paths', 'secondary-restore-via-primary', 'slow-write-answers-writing-then-status-finds-result',
    'remote-command-sent-after-open-with-rules', 'reopen-keeps-restorable-write-in-history', 'remote-restore-from-history',
    'remote-open-keeps-other-canvas-in-progress', 'remote-open-replaces-finished-plan', 'non-primary-remote-writes-blocked',
  ]) assert.ok(output.includes(`W180DISTILL PASS ${name}\n`), name);
});
