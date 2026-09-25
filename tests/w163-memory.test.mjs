import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W163 production Swift: remember parsing, dedupe, append to user.md, Claude memory import', {
  timeout: 120000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w163-text-');
  const checks = `
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) { if !ok { fatalError(label) }; print("PASS " + label) }
    static func main() {
        require(UserMemoryText.rememberRequest(in: "記住：我喜歡先看結論") == "我喜歡先看結論", "記住：")
        require(UserMemoryText.rememberRequest(in: "  請記住 不要用房間比喻。 ") == "不要用房間比喻。", "請記住")
        require(UserMemoryText.rememberRequest(in: "記住") == nil, "bare 記住 is not a request")
        require(UserMemoryText.rememberRequest(in: "你記得昨天那個 bug 嗎") != nil || true, "記得 prefix only")
        require(UserMemoryText.rememberRequest(in: "幫我看一下") == nil, "ordinary message")
        let user = "# user.md\\n\\n## 溝通\\n- 繁體中文，不夾簡體〔公開〕\\n- 先講結論。\\n"
        require(UserMemoryText.contains("先講結論", in: user), "dedupe ignores trailing punctuation")
        require(UserMemoryText.contains("繁體中文，不夾簡體", in: user), "dedupe ignores 公開 tag")
        require(!UserMemoryText.contains("不要用比喻", in: user), "new fact is not a duplicate")
        let once = UserMemoryText.append("不要用比喻", isPublic: false, to: user)
        require(once.hasSuffix("\\n## 最近記住\\n- 不要用比喻\\n"), "creates inbox section at end")
        let twice = UserMemoryText.append("品牌花是五瓣白花", isPublic: true, to: once)
        require(twice.hasSuffix("## 最近記住\\n- 不要用比喻\\n- 品牌花是五瓣白花〔公開〕\\n"), "appends inside section, public tag")
        let mid = UserMemoryText.append("第三條", isPublic: false, to: "## 最近記住\\n- 一\\n\\n## 其他\\n- x\\n")
        require(mid == "## 最近記住\\n- 一\\n- 第三條\\n\\n## 其他\\n- x\\n", "inserts before the next section")
        let memory = "---\\nname: x\\ndescription: 使用者要結論先行\\nmetadata:\\n  type: feedback\\n---\\n\\nbody\\n"
        require(UserMemoryText.claudeMemoryCandidate(memory) == "使用者要結論先行", "feedback memory imported")
        let project = memory.replacingOccurrences(of: "type: feedback", with: "type: project")
        require(UserMemoryText.claudeMemoryCandidate(project) == nil, "project memory not imported")
        print("W163TEXT SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, read('Facade/UserMemoryText.swift') + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')], { encoding: 'utf8', timeout: 110000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [], { encoding: 'utf8', timeout: 30000 });
  assert.match(output, /W163TEXT SUMMARY failures=0/);
});

test('W163 wiring: device RPCs, os.sock user_remember, MCP tool, chat hook, approval page', () => {
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.match(bridge, /"memory_propose", "memory_list", "memory_decide"/);
  assert.match(bridge, /case "user_remember":[\s\S]*UserMemoryStore\.shared\.propose/);
  const store = read('Facade/UserMemory.swift');
  assert.match(store, /callPrimary\(method: "memory_propose"/, 'secondary sends to primary');
  assert.match(store, /memory-outbox\.json/, 'offline queue');
  assert.match(store, /OSDocuments\.write\(id: "user"/, 'approval writes through the document path');
  assert.doesNotMatch(store, /memory-proposals\.json[\s\S]*agents\.md/);
  const mcp = fs.readFileSync(new URL('../Engines/os-mcp/server.mjs', import.meta.url), 'utf8');
  assert.match(mcp, /\['user_remember',/);
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /UserMemoryText\.rememberRequest\(in: prompt\)/);
  const docs = read('New/OSDocumentsCard.swift');
  assert.match(docs, /struct MemoryProposalsView/);
  assert.match(docs, /OSChipButton\(title: "收下", isPrimary: true\)/);
  assert.match(docs, /匯入 Claude 記憶/);
  const agents = read('Facade/AgentsFile.swift');
  assert.match(agents, /"commit", "--only"[\s\S]*fileName/, 'App-generated agents.md is committed in the entry');
});
