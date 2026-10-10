import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {testScratch} from './helpers/test-scratch.mjs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('1 native regression types /go using window keyDown events', () => {
  const fixture = read('Chat/W288Acceptance.swift');
  assert.match(fixture, /NSEvent\.keyEvent\(with: \.keyDown/);
  assert.match(fixture, /shot\.window\.sendEvent\(event\)/);
  assert.match(fixture, /first Return completes first suggestion without send/);
});
test('2 running toolbar keeps Stop at the right edge after the draft action', () => {
  const source = read('Chat/ChatPage+Composer.swift');
  assert.match(source, /if model\.isRunning \{\s*if model\.canSend \{ composerSendButton[^\n]*\}\s*composerStopButton/);
  assert.match(source, /accessibilityIdentifier\("chat-composer-stop"\)/);
});
test('3 Coder reuses the DM voice components and bounds their lifetime', () => {
  const composer = read('Chat/ChatPage+Composer.swift'), page = read('Chat/ChatPage.swift');
  assert.match(composer, /routeChoice\.runtimeAdapter == \.chatgptTap[\s\S]*ChatGPTVoiceModeButton/);
  assert.match(page, /ChatGPTVoiceOverlay\(model: coderVoice/);
  assert.match(page, /ChatGPTVoiceMode\(tap: \.shared, holderNotice: "Coder 的語音模式還開著"\)/);
  assert.match(composer, /onDisappear \{ coderVoice\.endVoice\(\) \}/);
});
test('4 both panel directions dismiss the previous floating panel', () => {
  const composer = read('Chat/ChatPage+Composer.swift');
  assert.match(composer, /if willShow \{\s*infoCardFloatingOpen = false; model\.dismissComposerSigil\(\)/);
  assert.match(composer, /onChange\(of: infoCardFloatingOpen\)[\s\S]*showUltraworkPanel = false/);
});
test('5 plan empty state and accessibility labels are Chinese', () => {
  const plan = read('Chat/ChatPage+Plan.swift');
  assert.match(plan, /目前沒有計畫/);
  assert.doesNotMatch(plan, /No plan is available|Close plan side panel|Download plan|Edit plan|Finish editing plan|Open plan in side panel|Copy markdown|Writing plan|Expand plan summary|Collapse plan summary/);
});
test('6 archived canvases reuse the neighbouring glass chip styling', () => {
  const menu = read('Chat/ChatPage+Composer.swift').split('if !model.archivedPlanCanvases.isEmpty')[1].split('// 「工作中」')[0];
  assert.match(menu, /menuStyle\(\.borderlessButton\)[\s\S]*chatGlassChip\(\)/);
  assert.match(menu, /menuStyle\(\.borderlessButton\)/);
  assert.match(menu, /menuIndicator\(\.hidden\)/);
});
test('7 actual Swift stderr classifier suppresses memory worker errors and preserves user errors', () => {
  const source = read('Facade/ChatLiveEngine.swift');
  const helper = source.match(/    static func engineStderrHint\(_ s: String\) -> String\? \{[\s\S]*?\n    \}/)?.[0];
  assert.ok(helper);
  assert.match(source, /case \.stderr\(let s\):\s*if let hint = Self\.engineStderrHint\(s\) \{ onHint\?\(hint\) \}/);
  const scratch = testScratch('w288-stderr-');
  writeFileSync(join(scratch, 'main.swift'), `import Foundation\nstruct Probe {\n${helper}\n}\n` + String.raw`
let memory = "2026-10-08T01:00:00Z ERROR codex_core::memories::phase2: error=apply_patch verification failed: /fixture/engines/codex/memories/memory_summary.md"
precondition(Probe.engineStderrHint(memory) == nil)
precondition(Probe.engineStderrHint("\u{1B}[31m" + memory + "\u{1B}[0m") == nil)
for line in [memory.replacingOccurrences(of: "codex_core::memories::phase2", with: "codex_core::tools::handlers::apply_patch"),
 "apply_patch verification failed: engines/codex/memories/memory_summary.md", "ERROR current turn failed", "permission denied"] {
 precondition(Probe.engineStderrHint(line) != nil, "user error hidden")
}
precondition(Probe.engineStderrHint("2026-10-08T01:00:00Z INFO codex_core::turn: progress") == nil)
precondition(Probe.engineStderrHint("(node:1234) [DEP] Warning: runtime") == nil)
print("W288 STDERR checks=8 failures=0")
`);
  const binary = join(scratch, 'probe');
  const build = spawnSync('swiftc', [join(scratch, 'main.swift'), '-o', binary], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stderr);
  const result = spawnSync(binary, [], {encoding:'utf8'});
  assert.equal(result.status, 0, result.stderr);
  console.log(result.stdout.trim());
});
test('8 /pr explicitly describes contribution to the public repository', () => {
  assert.match(read('Facade/ChatPageModel.swift'), /subtitle: "貢獻到 TATWO OS 公開倉（只在公開倉或其 fork 使用）"/);
});
