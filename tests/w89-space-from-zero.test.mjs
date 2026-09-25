import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W89 production Swift: empty workspace precondition picks owner, bot gate, project gate', {
  timeout: 120000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w89-precondition-');
  // 生產檔原樣編譯（不抄一份），只補一個 @main 跑判斷。
  const production = read('Space/SpaceCreation.swift');
  const checks = `
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) {
        if !ok { fatalError(label) }
        print("PASS " + label)
    }
    static func main() {
        require(SpaceCreation.outcome(botIDs: [], selectedBotID: nil) == .ready(ownerBotID: nil),
                "no bot still ready, owner unset (W160)")
        require(SpaceCreation.outcome(botIDs: ["bot-a", "bot-b"], selectedBotID: nil)
                == .ready(ownerBotID: "bot-a"), "no selection falls back to first library bot")
        require(SpaceCreation.outcome(botIDs: ["bot-a", "bot-b"], selectedBotID: "bot-b")
                == .ready(ownerBotID: "bot-b"), "selected bot becomes owner")
        require(SpaceCreation.outcome(botIDs: ["bot-a"], selectedBotID: "bot-missing")
                == .ready(ownerBotID: "bot-a"), "stale selection falls back to first library bot")
        require(SpaceCreation.domainFolder(entryRoot: "/e", domainID: "space-x") == "/e/spaces/space-x", "domain folder under entry")
        require(SpaceCreation.defaultDensity == "compact", "default density is compact")
        require(SpaceCreation.normalizedName("  第一個領域  ") == "第一個領域", "name trimmed")
        require(SpaceCreation.normalizedName("   ") == nil, "blank name rejected")
        require(SpaceCreation.nameFromPath("/synthetic/w89/open design") == "open design", "name from last path component")
        require(SpaceCreation.nameFromPath("  ") == nil, "blank path has no name")
        require(SpaceCreation.createTitle == "建立第一個領域", "create title")
        require(SpaceCreation.successText(name: "第一個領域") == "已建立領域 第一個領域", "success text")
        print("W89PRECONDITION SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, production + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')],
    { encoding: 'utf8', timeout: 110000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [], { encoding: 'utf8', timeout: 30000 });
  assert.match(output, /W89PRECONDITION SUMMARY failures=0/);
  assert.ok(output.includes('PASS no bot still ready, owner unset (W160)'), 'ownerless case must run');
});

test('W89 settings › Space empty state is not an error and owns the only creation path', () => {
  const controller = read('Space/SpaceWorkspaceController.swift');
  // 0 個 space 不再寫 error。
  assert.doesNotMatch(controller, /尚無領域 Space/);
  // W171：全新安裝自動建一個領域，直接顯示 Space 頁；失敗才退回空狀態。
  assert.match(controller, /guard !domains\.isEmpty else \{\n\s*if !triedDefaultDomain \{[\s\S]*createSpace\(\n?\s*name: SpaceCreation\.defaultDomainName[\s\S]*isEmptyWorkspace = true\n\s*return\n\s*\}/);
  const create = controller.slice(controller.indexOf('    func createDomain('),
                                  controller.indexOf('    private func restore('));
  assert.match(create, /SpaceCreation\.normalizedName\(rawName\)/);
  // W160：不再因為沒有 bot 擋下。
  assert.doesNotMatch(create, /\.blocked/);
  assert.match(create, /guard case \.ready\(let owner\) = creationOutcome\(selectedBotID: ownerBotID\)/);
  assert.match(create, /createSpace\(name: name, density: density \?\? SpaceCreation\.defaultDensity, ownerBotID: owner\)/);
  assert.match(create, /await load\(library: library\)/);
  assert.match(create, /selectDomain\(space\.id\)/);

  const view = read('Space/SpaceLiveSetupView.swift');
  const empty = view.slice(view.indexOf('struct SpaceEmptyDomainView'), view.indexOf('struct SpaceLiveConversationView'));
  // 空狀態不再顯示「Work Space 資料未就緒」；讀取中仍然顯示讀取文案。
  assert.doesNotMatch(empty, /Work Space 資料未就緒/);
  assert.match(view, /controller\.error == nil \? SpaceCreation\.loadingText : "Work Space 資料未就緒"/);
  assert.match(view, /\} else if controller\.isEmptyWorkspace \{\n\s*SpaceEmptyDomainView\(\)/);
  assert.match(empty, /Text\(SpaceCreation\.emptyExplanation\)/);
  assert.match(empty, /Button\(SpaceCreation\.createTitle, action: create\)/);
  assert.match(empty, /\.onSubmit\(create\)/);
  // W160：空狀態只有名稱欄與建立鈕，沒有「先建立 bot」「先選擇專案」的擋路分支。
  assert.doesNotMatch(empty, /needsBot|needsProject|openBotPage/);
});

test('W89 Bot page 三段流 live 走同一條建立函式；fixture 維持展示文案', () => {
  const state = read('Bot/BotPageState.swift');
  const complete = state.slice(state.indexOf('    func addSpaceComplete('), state.indexOf('    /// 取消/Esc'));
  assert.match(complete, /guard usesLiveBots else \{ return \}/);
  assert.match(complete, /SpaceWorkspaceController\.shared\.createDomain\(name: rawName, ownerBotID: owner, density: density\)/);
  assert.match(complete, /case \.created\(_, let created\): addSpaceCreatedName = created/);
  assert.match(complete, /case \.failed\(let message\): addSpaceFailure = message/);

  const page = read('Bot/BotPage.swift');
  const completion = page.slice(page.indexOf('            case .completionMock:'),
                                page.indexOf('        .frame(maxWidth: .infinity, maxHeight: .infinity)\n        .padding(24)\n    }\n\n    // MARK: - 右緣書側標籤'));
  assert.match(completion, /state\.addSpaceCreatedName\.map\(SpaceCreation\.successText\(name:\)\)/);
  assert.match(completion, /\?\? "已交由 agent 搭建（展示）"/);
  assert.match(completion, /state\.addSpaceFailure/);
  assert.match(page, /state\.addSpaceComplete\(name: SpaceCreation\.nameFromPath\(addSpacePath\) \?\? addSpacePath,\s*density: state\.addSpaceDensity\?\.rawValue\)/);
});

test('W89 dead code removed: BotStore fixtureSeed/systemPrompt gone, live library reused', () => {
  const store = read('Facade/BotStore.swift');
  assert.doesNotMatch(store, /fixtureSeed/);
  assert.doesNotMatch(store, /static func systemPrompt/);
  assert.match(store, /init\(library: BotLibrary\)/);
  // W160：owner 可為 nil（還沒有 bot 的領域）。
  assert.match(store, /func createSpace\(name: String, density: String, ownerBotID: String\?\) async throws -> BotSpaceRecord/);
  const sources = fileURLToPath(new URL('../App/Sources', import.meta.url));
  const survivors = spawnSync('grep', ['-rl', 'fixtureSeed', sources], { encoding: 'utf8' });
  assert.equal(survivors.stdout.trim(), '', 'no caller may reference the removed seed');
});

test('W89 production binary: from zero, a domain without a bot and one with a bot', {
  timeout: 180000,
  skip: process.env.TATWO2_TEST_BINARY ? false : 'TATWO2_TEST_BINARY required (built Tatwo2 debug binary)',
}, () => {
  const root = testScratch('w89-from-zero-');
  const home = path.join(root, 'isolated-process-home');
  fs.mkdirSync(home);
  const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
    encoding: 'utf8', timeout: 150000,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, CFFIXED_USER_HOME: home,
      TATWO2_W89_TEST_ROOT: root, TATWO2_LIVE_ROOT: path.join(root, 'live') },
  });
  for (const label of ['empty-library-is-not-error', 'empty-library-gets-default', 'no-bot-ready-without-owner',
    'no-bot-creates-domain', 'bot-owner-ready',
    'created-trimmed-name', 'controller-three-domains', 'bot-spaces-json-three-records',
    'owner-bot-links-space', 'blank-name-rejected']) {
    assert.ok(output.includes('W89TEST PASS ' + label), label + '\n' + output);
  }
  assert.match(output, /W89TEST SUMMARY failures=0/);
  const spaces = JSON.parse(fs.readFileSync(path.join(root, 'live', 'bot-spaces.json'), 'utf8'));
  // W171：全新安裝自動有「我的 Space」；W160：再建一個沒有 bot 的領域（owner 空）、一個有 bot 的。
  assert.equal(spaces.length, 3);
  assert.equal(spaces[0].name, '我的 Space');
  assert.equal(spaces[1].name, '沒有 bot 的領域');
  assert.equal(spaces[1].ownerBotID, '');
  assert.equal(spaces[2].name, '第一個領域');
  assert.equal(spaces[2].density, 'compact');
});
