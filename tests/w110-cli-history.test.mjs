// W110：CLI 分頁「過去的對話」。各家 CLI 的 session 檔只讀、不複製；這裡驗讀取元件與接線。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, utimesSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

test('治理：讀取元件只讀，不寫檔、不刪檔、不連網、不進 RPC', () => {
  const reader = read('Facade/CLITranscriptArchive.swift');
  for (const banned of [/\.write\(/, /removeItem/, /moveItem/, /copyItem/, /createFile/, /URLSession/, /forWritingTo/, /forUpdating/])
    assert.doesNotMatch(reader, banned);
  assert.doesNotMatch(read('Facade/OSAgentBridge.swift'), /CLITranscript/);   // 第一版不給 OS 內 AI 讀歷史
  assert.match(reader, /guard UUID\(uuidString: session\.sessionID\) != nil/);   // id 會進終端指令
});

test('接線：側欄入口、主畫面切換、接續走引擎自己的 resume、解析不在主執行緒', () => {
  const sidebar = read('Chat/ChatPage+Sidebar.swift');
  assert.match(sidebar, /Button \{ model\.cliHistoryPresented\.toggle\(\) \}/);
  assert.match(sidebar, /send: \{ model\.cliHistoryPresented = false; model\.sendCLIWorkbench\(\$0\) \}/);   // 點終端分頁就回到終端
  assert.match(read('Chat/ChatPage+Panels.swift'), /if model\.cliHistoryPresented \{\s*CLITranscriptHistoryView\(sources: model\.cliTranscriptSources,/);
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /isLive \? CLITranscriptArchive\.defaultSources\(enginesRoot: engineLogin\.paths\.enginesRoot\) : \[\]/);   // 假資料模式不讀真實對話
  assert.match(model, /case \.native:[\s\S]{0,260}openCLITab\(engine: \.generic, workdir: cwd\)/);   // 使用者自己的 CLI 不套 OS 隔離家目錄
  assert.match(model, /case \.osEngine:\s*guard openCLITab\(engine: session\.engine == \.claude \? \.claude : \.codex, workdir: cwd, extraArguments: arguments\)/);
  const view = read('New/CLITranscriptHistoryView.swift');
  assert.equal((view.match(/Task\.detached\(priority: \.userInitiated\)/g) || []).length, 2);
  assert.match(view, /讀取中 \\\(percent\)%/);   // 大檔有進度數字   // 清單與內容都在背景讀
  assert.equal((view.match(/onCancel: \{ work\.cancel\(\) \}/g) || []).length, 2);              // 切走就停
  assert.doesNotMatch(view, /URLSession|\.write\(|removeItem|NSPasteboard/);
  for (const text of ['這台設備上還沒有 CLI 對話紀錄', '選一段對話來讀', '在 Finder 顯示原檔', '完整內容在原檔裡']) assert.ok(view.includes(text), text);
});

test('讀取元件：清單、內容、壞行、截斷、子代理、接續條件', () => {
  const work = mkdtempSync(join(tmpdir(), 'w110-history-'));
  const old = new Date(Date.now() - 3600_000);
  const cid = '11111111-2222-4333-8444-555555555555', xid = '01a0ab5e-7bc2-7980-866c-209c54e76456';
  const cdir = join(work, 'claude/projects/-tmp-demo'); mkdirSync(join(cdir, cid, 'subagents'), { recursive: true });
  const line = o => JSON.stringify(o);
  const claude = [
    line({ type: 'user', cwd: '/tmp/demo', entrypoint: 'cli', sessionId: cid, timestamp: '2026-09-19T01:02:03.456Z', message: { role: 'user', content: '<system-reminder>內部提醒</system-reminder>幫我看一下 git 狀態' } }),
    line({ type: 'user', isMeta: true, message: { role: 'user', content: '不該出現的 meta' } }),
    '{這一行壞掉了',
    line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'thinking', thinking: '…' }, { type: 'text', text: '我來看。' }, { type: 'tool_use', name: 'Bash', input: { command: 'git status' } }] } }),
    line({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', content: 'x'.repeat(9000) }] } }),
    line({ type: 'attachment', attachment: { big: 'y'.repeat(2000) } }),
    line({ type: 'user', isCompactSummary: true, message: { role: 'user', content: '前情摘要' } }),
    line({ type: 'assistant', isSidechain: true, message: { role: 'assistant', content: [{ type: 'text', text: '子代理的話' }] } }),
    line({ type: 'ai-title', aiTitle: '檢查 git 狀態', sessionId: cid }),
  ].join('\n') + '\n';
  writeFileSync(join(cdir, `${cid}.jsonl`), claude); utimesSync(join(cdir, `${cid}.jsonl`), old, old);
  writeFileSync(join(cdir, cid, 'subagents', 'agent-1.jsonl'), line({ type: 'user', cwd: '/tmp/demo', message: { content: 'sub' } }) + '\n');
  writeFileSync(join(cdir, 'not-a-uuid.jsonl'), line({ type: 'user', cwd: '/tmp/demo', entrypoint: 'sdk-cli', message: { content: '沒有 id 的對話' } }) + '\n');
  utimesSync(join(cdir, 'not-a-uuid.jsonl'), old, old);
  const xdir = join(work, 'codex/sessions/2026/09/17'); mkdirSync(xdir, { recursive: true });
  const codex = [
    line({ timestamp: '2026-09-17T01:00:00.000Z', type: 'session_meta', payload: { id: xid, cwd: '/tmp/room', source: 'exec' } }),
    line({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '# AGENTS.md instructions\n<INSTRUCTIONS>x</INSTRUCTIONS>' }] } }),
    line({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '<environment_context>cwd</environment_context>' }] } }),
    line({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '施工單：修側欄' }] } }),
    line({ type: 'response_item', payload: { type: 'reasoning', summary: [] } }),
    line({ type: 'response_item', payload: { type: 'function_call', name: 'shell', arguments: '{"cmd":"ls"}' } }),
    line({ type: 'response_item', payload: { type: 'function_call_output', output: 'a\nb' } }),
    line({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '完成' }] } }),
    line({ type: 'event_msg', payload: { type: 'token_count' } }),
  ].join('\n') + '\n';
  const sid = '01a0ab5e-7bc2-7980-866c-209c54e76999';
  writeFileSync(join(xdir, `rollout-2026-09-17T02-00-00-${sid}.jsonl`), [line({ type: 'session_meta', payload: { id: sid, cwd: '/tmp/room', originator: 'tatwo2-codex-sidecar', source: 'vscode' } }),
    line({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'OS 聊天裡問的' }] } })].join('\n') + '\n');
  writeFileSync(join(xdir, `rollout-2026-09-17T01-00-00-${xid}.jsonl`), codex);   // 剛寫入：不給接續
  writeFileSync(join(work, 'main.swift'), `
import Foundation
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + " " + detail); if !ok { exit(1) } }
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let sources = [CLITranscriptArchive.Source(root: base.appendingPathComponent("claude/projects"), engine: .claude, origin: .native),
               CLITranscriptArchive.Source(root: base.appendingPathComponent("codex/sessions"), engine: .codex, origin: .osEngine),
               CLITranscriptArchive.Source(root: base.appendingPathComponent("missing"), engine: .claude, origin: .native)]
let all = CLITranscriptArchive.list(sources: sources)
check("four sessions, subagent skipped", all.count == 4, "\\(all.map(\\.title))")
let c = all.first { $0.sessionID == "${cid}" }!
check("claude title from ai-title", c.title == "檢查 git 狀態", c.title)
check("claude cwd", c.cwd == "/tmp/demo" && c.origin == .native && !c.isBatch)
let items = CLITranscriptArchive.read(c)
check("kinds", items.map(\\.kind) == [.user, .assistant, .toolCall, .toolResult, .summary], "\\(items.map(\\.kind))")
check("reminder stripped", items[0].text == "幫我看一下 git 狀態", items[0].text)
check("timestamp", items[0].timestamp != nil)
check("tool call", items[2].toolName == "Bash" && items[2].text.contains("git status"), items[2].text)
check("tool result clipped", items[3].text.count == CLITranscriptArchive.toolLimit && items[3].clipped == 1000, "\\(items[3].clipped)")
var seen: [Int] = []; let lock = NSLock()
_ = CLITranscriptArchive.read(c) { p in lock.lock(); seen.append(p); lock.unlock() }
check("progress reaches 100", seen.last == 100 && seen == seen.sorted(), "\\(seen)")
check("ids sequential", items.map(\\.id) == Array(0..<items.count))
check("claude resume", CLITranscriptArchive.resumeArguments(c) == ["--resume", "${cid}"])
let n = all.first { $0.sessionID == "not-a-uuid" }!
check("title falls back to first user line", n.title == "沒有 id 的對話", n.title)
check("sdk entrypoint counts as non-interactive", n.isBatch)
check("non-uuid cannot resume", CLITranscriptArchive.resumeArguments(n) == nil && CLITranscriptArchive.resumeBlockedReason(n) != nil)
let x = all.first { $0.sessionID == "${xid}" }!
check("os chat sidecar counts as non-interactive", all.first { $0.sessionID == "${sid}" }?.isBatch == true)
check("codex meta", x.sessionID == "${xid}" && x.cwd == "/tmp/room" && x.isBatch && x.origin == .osEngine, "\\(x)")
check("codex title skips wrappers", x.title == "施工單：修側欄", x.title)
let xi = CLITranscriptArchive.read(x)
check("codex kinds", xi.map(\\.kind) == [.user, .toolCall, .toolResult, .assistant], "\\(xi.map(\\.kind))")
check("codex tool", xi[1].toolName == "shell" && xi[2].text == "a\\nb")
check("fresh file cannot resume", CLITranscriptArchive.resumeArguments(x) == nil)
check("old file resumes", CLITranscriptArchive.resumeArguments(x, now: Date().addingTimeInterval(3600)) == ["resume", "${xid}"])
`);
  const build = spawnSync('swiftc', ['-O', join(root, 'App/Sources/Tatwo2/Facade/CLITranscriptArchive.swift'), join(work, 'main.swift'), '-o', join(work, 'probe')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const before = readFileSync(join(cdir, `${cid}.jsonl`), 'utf8');
  const run = spawnSync(join(work, 'probe'), [work], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal((run.stdout.match(/^PASS /gm) || []).length, 21, run.stdout);
  assert.equal(readFileSync(join(cdir, `${cid}.jsonl`), 'utf8'), before);   // 讀完原檔一個位元組都沒動
  assert.ok(!existsSync(join(work, 'missing')));
});
