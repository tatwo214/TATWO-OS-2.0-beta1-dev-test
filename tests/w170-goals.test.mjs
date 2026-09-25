import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W170 production Swift: goal list only appends, guards completion, keeps one active, handles proposals', {
  timeout: 120000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w170-rules-');
  const checks = `
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) { if !ok { fatalError(label) }; print("PASS " + label) }
    static func fails(_ label: String, _ expected: ThreadGoalRules.Failure, _ body: () throws -> Void) {
        do { try body(); require(false, label) } catch let e as ThreadGoalRules.Failure { require(e == expected, label) } catch { require(false, label) }
    }
    static func main() throws {
        var list = ThreadGoalList()
        let a = try ThreadGoalRules.add(&list, title: "設定 › OS 合併", userWords: "處理", proposed: false)
        let b = try ThreadGoalRules.add(&list, title: "Space 不用先有 bot", userWords: nil, proposed: false)
        require(a.id == 1 && b.id == 2 && list.nextID == 3, "ids append")
        fails("empty title rejected", .emptyTitle) { _ = try ThreadGoalRules.add(&list, title: "  ", userWords: nil, proposed: false) }
        try ThreadGoalRules.setStatus(&list, id: 1, to: .active, evidence: nil, actor: .lead)
        try ThreadGoalRules.setStatus(&list, id: 2, to: .active, evidence: nil, actor: .lead)
        require(list.goals[0].status == .pending && list.goals[1].status == .active, "only one active at a time")
        fails("lead needs evidence", .evidenceRequired) { try ThreadGoalRules.setStatus(&list, id: 2, to: .done, evidence: nil, actor: .lead) }
        try ThreadGoalRules.setStatus(&list, id: 2, to: .done, evidence: "  ", actor: .sub)
        require(list.goals[1].status == .review, "sub done becomes review")
        try ThreadGoalRules.setStatus(&list, id: 2, to: .done, evidence: "w89 5 項過", actor: .lead)
        require(list.goals[1].status == .done && list.goals[1].evidence == "w89 5 項過", "lead completes with evidence")
        fails("pause is user only", .userOnly) { try ThreadGoalRules.setStatus(&list, id: 1, to: .paused, evidence: nil, actor: .lead) }
        let p = try ThreadGoalRules.add(&list, title: "順便清死 MCP", userWords: nil, proposed: true)
        fails("proposal cannot start", .proposedNeedsApproval) { try ThreadGoalRules.setStatus(&list, id: p.id, to: .active, evidence: nil, actor: .lead) }
        require(ThreadGoalRules.progress(list) == (1, 2), "progress ignores proposals")
        let summary = ThreadGoalRules.promptSummary(list)!
        require(summary.contains("已完成 1／2") && summary.contains("○ 1. 設定 › OS 合併") && summary.contains("◇ 3. 順便清死 MCP（AI 提議，未核准）")
                && !summary.contains("Space 不用先有 bot"), "summary lists only open goals")
        try ThreadGoalRules.decideProposal(&list, id: p.id, accept: false)
        require(list.goals.count == 2 && list.nextID == 4, "rejected proposal removed, id not reused")
        let q = try ThreadGoalRules.add(&list, title: "再一條", userWords: nil, proposed: true)
        try ThreadGoalRules.decideProposal(&list, id: q.id, accept: true)
        require(list.goals.last?.proposed == false && q.id == 4, "accepted proposal joins mainline")
        fails("lead cannot edit", .userOnly) { try ThreadGoalRules.edit(&list, id: 1, title: "改", remove: false, actor: .lead) }
        try ThreadGoalRules.edit(&list, id: 1, title: "設定 › OS 與文件合併", remove: false, actor: .user)
        require(list.goals[0].title == "設定 › OS 與文件合併", "user edits title")
        var empty = ThreadGoalList()
        require(ThreadGoalRules.promptSummary(empty) == nil, "no goals, no summary")
        _ = try ThreadGoalRules.add(&empty, title: "子目標", userWords: nil, proposed: false, parent: 1)
        require(ThreadGoalRules.progress(empty) == (0, 0), "subgoals not counted in mainline progress")
        // 2026-09-22 使用者選：父目標完成時，待驗收的子目標一起完成；還在做的擋住主導、使用者可強制收掉。
        var tree = ThreadGoalList()
        let parent = try ThreadGoalRules.add(&tree, title: "派工驗收場加兩支腳本", userWords: nil, proposed: false)
        let roomA = try ThreadGoalRules.add(&tree, title: "A", userWords: nil, proposed: false, parent: parent.id)
        let roomB = try ThreadGoalRules.add(&tree, title: "B", userWords: nil, proposed: false, parent: parent.id)
        try ThreadGoalRules.setStatus(&tree, id: roomA.id, to: .active, evidence: nil, actor: .lead)
        try ThreadGoalRules.setStatus(&tree, id: roomB.id, to: .done, evidence: "b168f96", actor: .sub)
        fails("lead cannot close parent while a room works", .openChildren(1)) {
            try ThreadGoalRules.setStatus(&tree, id: parent.id, to: .done, evidence: "驗過", actor: .lead)
        }
        require(tree.goals[0].status == .pending, "blocked close changes nothing")
        try ThreadGoalRules.setStatus(&tree, id: roomA.id, to: .done, evidence: "ce00c22", actor: .sub)
        try ThreadGoalRules.setStatus(&tree, id: parent.id, to: .done, evidence: "驗過", actor: .lead)
        require(tree.goals.allSatisfy { $0.status == .done }, "parent done closes review subgoals")
        var forced = ThreadGoalList()
        let top = try ThreadGoalRules.add(&forced, title: "房間掛了", userWords: nil, proposed: false)
        let stuck = try ThreadGoalRules.add(&forced, title: "卡住的房間", userWords: nil, proposed: false, parent: top.id)
        try ThreadGoalRules.setStatus(&forced, id: stuck.id, to: .active, evidence: nil, actor: .lead)
        try ThreadGoalRules.setStatus(&forced, id: top.id, to: .done, evidence: nil, actor: .user)
        require(forced.goals.allSatisfy { $0.status == .done }, "user closing parent closes everything under it")
        print("W170RULES SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, read('Facade/ThreadGoalRules.swift') + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')], { encoding: 'utf8', timeout: 110000 });
  assert.equal(build.status, 0, build.stderr);
  assert.match(execFileSync(path.join(root, 'fixture'), [], { encoding: 'utf8', timeout: 30000 }), /W170RULES SUMMARY failures=0/);
});

test('W170 wiring: /goal for every engine, plan and plg create goals, engine tools, per-turn summary, Coder name, sidebar untouched', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /first == "\/goal" \{[\s\S]*ThreadGoalRules\.add\(&\$0, title: text, userWords: text, proposed: false\)/);
  assert.match(model, /prompt = ""\n[\s\S]{0,120}if isLocalNativeGoalCommand, engineLogin\.status\(for: \.codex\)\.isLoggedIn \{\n\s*let accepted = localLive\?\.setNativeGoal/, 'goal clears the composer once listed; OpenAI still hands it to the native goal');
  assert.doesNotMatch(model, /目前無法建立目標，草稿已保留/, 'a listed goal never leaves a draft behind to be added twice');
  assert.match(model, /userWords: "計畫：" \+ title/, 'confirmed plan becomes a goal');
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.match(bridge, /case "goal_list", "goal_propose", "goal_update":/);
  assert.match(bridge, /goal\.roomThread = room\.threadID/, 'plg rooms become sub-goals');
  assert.match(bridge, /roomGoal != nil \? \(parentID!, \.sub\) : \(caller, \.lead\)/, 'dispatched work acts as sub');
  assert.match(read('Facade/ChatLiveEngine.swift'), /ThreadGoalRules\.promptSummary\(ThreadGoalStore\.shared\.list\(threadID\)\)/);
  // 實測：Claude CLI 把開頭的 /plg 當成自己的斜線指令（Unknown command），引擎沒收到；送出前要翻成白話。
  assert.match(read('Facade/ChatLiveEngine.swift'), /let engineText = Self\.engineText\(t\)\n\s*var outgoing = engineText/);
  assert.match(read('Facade/ChatLiveEngine.swift'), /first == "\/plg" else \{ return text \}[\s\S]*dispatch_rooms/);
  const mcp = fs.readFileSync(new URL('../Engines/os-mcp/server.mjs', import.meta.url), 'utf8');
  for (const tool of ['goal_list', 'goal_propose', 'goal_update']) assert.match(mcp, new RegExp(`\\['${tool}',`));
  assert.match(read('Chat/ChatPageConstants.swift'), /if case \.chat = self \{ return "Coder" \}/);
  assert.match(read('Chat/ChatPageConstants.swift'), /case \.chat: "Chat"/, 'saved key unchanged');
  // 2026-09-22 使用者：位置改到輸入框上方，和派工（/plg）那列合成一張；右上角不再放。
  assert.doesNotMatch(read('Chat/ChatPage.swift'), /ThreadGoalCard\(/);
  const composer = read('Chat/ChatPage+Composer.swift');
  const card = read('Chat/ThreadGoalCard.swift');
  assert.match(composer, /ThreadGoalCard\(threadID: thread[\s\S]*roomView: \{ ids, footer in\n\s*AnyView\(DispatchCard\(model: model, embedded: true, roomIDs: ids, showsFooter: footer\)\)/);
  // 房間併進目標那一列：綁了目標的房間畫在子目標上，「討論串」只放沒綁的。
  assert.match(card, /if let room = linkedRoom\(child\) \{[\s\S]*roomView\(\[room\], false\)/);
  assert.match(card, /roomsSection\(roomIDs\.filter \{ !linked\.contains\(\$0\) \}/);
  assert.match(composer, /\} else if showsRooms \{\n\s*DispatchCard\(model: model\)/, 'other surfaces keep the standalone dispatch card');
  assert.match(card, /OSChipButton\(title: "加入主線", isPrimary: true\)/);
  assert.doesNotMatch(card, /borderedProminent|Color\.accentColor/);
});
