import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W160 production Swift: agents.md is rendered from the constitution summary', {
  timeout: 120000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w160-agents-');
  // 合成憲法：摘要前有說明段、三級小節、之後接 §0；不用真的個人憲法。
  const constitution = [
    '# 憲法（合成）', '', '## 引擎摘要', '', '本節說明段，不進 agents.md。', '',
    '### 先理解', '冷啟動，先看檔案。', '', '### 邊界', '刪除先討論。', '', '快捷：`/plan` 只討論。', '',
    '## 0. 效力', '其他條文。', '',
  ].join('\n');
  fs.writeFileSync(path.join(root, 'constitution.md'), constitution);
  const checks = `
import Foundation
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) { if !ok { fatalError(label) }; print("PASS " + label) }
    static func main() throws {
        let c = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let out = AgentsRender.render(constitution: c)!
        require(out.hasPrefix("# agents.md：在這位使用者設備上工作的所有 AI\\n\\n由 TATWO OS"), "header first")
        require(out.contains("衝突以 \`~/AI/TATWO OS/os.md\` 為準。\\n\\n## 先理解\\n"), "blank line then first section")
        require(!out.contains("本節說明段"), "intro paragraph dropped")
        require(!out.contains("### "), "sections promoted to level two")
        require(!out.contains("其他條文"), "stops at next level-two heading")
        require(out.hasSuffix("快捷：\`/plan\` 只討論。\\n"), "single trailing newline")
        require(AgentsRender.render(constitution: "# 沒有摘要\\n## 0. 效力\\n") == nil, "no summary renders nothing")
        require(AgentsRender.render(constitution: "## 引擎摘要\\n只有說明沒有小節\\n") == nil, "summary without sections renders nothing")
        require(AgentsRender.render(constitution: "\\u{FEFF}" + c) == out, "BOM tolerated")
        // Round trip: a constitution built from an agents.md renders that same agents.md.
        let body = out.components(separatedBy: "\\n## ").dropFirst().map { "### " + $0 }.joined(separator: "\\n")
        let rebuilt = "## 引擎摘要\\n\\n說明。\\n\\n" + body + "\\n## 0. 效力\\n"
        require(AgentsRender.render(constitution: rebuilt) == out, "round trip is byte identical")
        print("W160AGENTS SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, read('Facade/AgentsRender.swift') + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')], { encoding: 'utf8', timeout: 110000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [path.join(root, 'constitution.md')], { encoding: 'utf8', timeout: 30000 });
  assert.match(output, /W160AGENTS SUMMARY failures=0/);
});

test('W160 dispatch carries the optional entry files and the primary refreshes agents.md first', () => {
  const dispatch = read('Facade/DeviceDispatch.swift');
  assert.match(dispatch, /optionalFiles = \["agents\.md", "user\.md", "todo\.md", "issue\.md"\]/);
  assert.match(dispatch, /Self\.optionalFiles\.contains\(path\)/, 'apply allowlist accepts optional files');
  assert.match(dispatch, /AgentsFile\.refresh\(entry: entry, role: local\.role\)[\s\S]*try snapshot\(\)/, 'refresh before snapshot');
  const generator = read('Facade/RuleGenerator.swift');
  assert.match(generator, /AgentsFile\.userPreferences/, 'built-in engines receive user.md');
});

test('W160 production Swift: engine link scan and link archive the original and never duplicate', {
  timeout: 150000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w160-links-');
  const home = path.join(root, 'home');
  const entry = path.join(home, 'AI', 'TATWO OS');
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.mkdirSync(path.join(home, '.codex', 'skills', 'skillet'), { recursive: true });
  fs.mkdirSync(entry, { recursive: true });
  fs.writeFileSync(path.join(entry, 'agents.md'), '# agents\n');
  fs.writeFileSync(path.join(entry, 'skillet.md'), '# skillet\n');
  fs.writeFileSync(path.join(home, '.claude', 'CLAUDE.md'), 'my own claude rules\n');
  fs.writeFileSync(path.join(home, '.codex', 'skills', 'skillet', 'SKILL.md'), 'old skillet copy\n');
  const stubs = `
import Foundation
enum OSUpstreamBinding { struct F: LocalizedError { let errorDescription: String? }; static func failure(_ s: String) -> Error { F(errorDescription: s) } }
enum OSUpstream { static func runtimePath(environment: [String: String]) -> String { "/nonexistent/os-upstream.md" } }
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) { if !ok { fatalError(label) }; print("PASS " + label) }
    static func main() throws {
        let home = CommandLine.arguments[1]
        let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": home + "/AI/TATWO OS"], preference: nil)
        var rows = EngineLinks.scan(entry: entry, home: home, runtimeUpstreamPath: "/nonexistent")
        func row(_ id: String) -> EngineLinkRow? { rows.first { $0.id == id } }
        require(row("claude")?.state == .notLinked, "own CLAUDE.md is not linked")
        require(row("codex")?.state == .notLinked, "missing AGENTS.md is not linked")
        require(row("openclaw") == nil, "no openclaw row without ~/.openclaw")
        require(row("grok-cli")?.state == .notApplicable, "grok cli not applicable")
        require(row("skillet")?.state == .notLinked, "old skillet copy is not linked")
        try EngineLinks.link(row("claude")!, entry: entry)
        try EngineLinks.link(row("skillet")!, entry: entry)
        rows = EngineLinks.scan(entry: entry, home: home, runtimeUpstreamPath: "/nonexistent")
        require(row("claude")?.state == .linked, "claude linked after link")
        require(row("skillet")?.state == .linked, "skillet linked after link")
        require((try? String(contentsOfFile: home + "/.claude/CLAUDE.md", encoding: .utf8)) == "# agents\\n", "reads entry agents.md through link")
        try EngineLinks.link(row("claude")!, entry: entry)
        print("W160LINKS SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, read('Facade/TatwoEntry.swift') + read('Facade/EngineLinks.swift').replace('import Foundation', '') + stubs);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')], { encoding: 'utf8', timeout: 140000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [home], { encoding: 'utf8', timeout: 30000 });
  assert.match(output, /W160LINKS SUMMARY failures=0/);
  const archived = fs.readdirSync(path.join(entry, 'archive', 'engine-rules'));
  assert.equal(archived.length, 1, 'one dated archive folder');
  const day = path.join(entry, 'archive', 'engine-rules', archived[0]);
  assert.equal(fs.readFileSync(path.join(day, 'claude', 'CLAUDE.md'), 'utf8'), 'my own claude rules\n', 'original preserved byte for byte');
  assert.deepEqual(fs.readdirSync(path.join(day, 'claude')).sort(), ['CLAUDE.md', 'MANIFEST.md'], 'second link archived nothing more');
  assert.equal(fs.readFileSync(path.join(day, 'skillet', 'SKILL.md'), 'utf8'), 'old skillet copy\n');
});

test('W160 settings: OS page shows engines and opens documents; separate 文件 tab is gone; onboarding asks about backup', () => {
  const settings = read('Shell/ChatPageSettings.swift');
  assert.doesNotMatch(settings, /case documents/);
  assert.match(settings, /OSSettingsPage\(model: model/);
  const page = read('New/OSSettingsPage.swift');
  assert.match(page, /OSChipButton\(title: "文件 ›"/);
  assert.doesNotMatch(page, /borderedProminent/, 'no system blue buttons');
  assert.match(page, /EngineLinks\.scan\(\)/);
  assert.doesNotMatch(page, /Button\("(預覽差異|寫入修復|保留已手改區塊)"/);
  const docs = read('New/OSDocumentsCard.swift');
  assert.match(docs, /"OS › 文件"/);
  assert.match(docs, /static func readers/);
  // 使用者 2026-09-22：內文不可即時修改，按「編輯」開畫布；不要藍色框。
  assert.doesNotMatch(docs.slice(0, docs.indexOf('private func canvas(')), /TextEditor\(text: \$draft\)/, 'no live editor in the reading view');
  assert.match(docs, /\.sheet\(isPresented: \$editing\)/);
  assert.match(docs, /OSChipButton\(title: "存檔", isPrimary: true\)/);
  assert.doesNotMatch(docs, /Color\.accentColor|borderedProminent/);
  // W171：備份不再是接入精靈的一步，改成 設定 › GitHub 的「初始設定」（使用者自己選）。
  const setup = read('Shell/SetupGuide.swift');
  assert.match(setup, /OSChipButton\(title: "備份到我的 GitHub", isPrimary: true\) \{ Task \{ await backup\.enable\(\) \} \}/);
  assert.match(setup, /OSChipButton\(title: "不用"\) \{ backup\.decline\(\) \}/);
  const backup = read('Facade/EntryBackup.swift');
  assert.match(backup, /"private": true/);
  assert.match(backup, /公開倉庫，不拿來放備份/);
  assert.doesNotMatch(backup, /arguments = \[[^\]]*token/, 'token never in argv');
});
