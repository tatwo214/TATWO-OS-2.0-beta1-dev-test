import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL('../App/Sources/Tatwo2/' + path, import.meta.url), 'utf8');

test('W192 A1 hidden idle Pod receives native visibility; active work wakes before dispatch', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  const pod = read('TAP/TapWebPod.swift');
  assert.match(tap, /transport\.setBackgroundWorkActive\(/);
  assert.match(pod, /browser\.isHidden =/);
  assert.match(read('Facade/ChatGPTTapAcceptance.swift'), /visibilityChecks/);
});

test('W192 U2 per-turn regressions follow capability reports and explicit effort after level', () => {
  const fix = read('Chat/TatwoComposerModeAcceptanceFix.swift');
  assert.match(fix, /first\?\.effort == expectedClaudeEffort/);
  const first = fix.slice(fix.indexOf('// P4'), fix.indexOf('model.prompt = "P4 Codex 第一輪"'));
  assert.ok(first.indexOf('setLevel(.m)') < first.indexOf('choose(TatwoCodexReasoningEffort.low.rawValue)'));
});

test('W192 I1 one glass reasoning control; Ultra stays an explicit choice', () => {
  const card = read('Chat/TatwoComposerModeCard.swift');
  const start = card.indexOf('private func stepsSection');
  const steps = card.slice(start, card.indexOf('private var footer:', start));
  assert.doesNotMatch(steps, /Menu\(/);
  assert.match(steps, /Button\("Ultra"\)/);
  assert.match(steps, /steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue/);
});

test('W192 I3 pastel glass fill uses dark ink for readable selected labels', () => {
  const card = read('Chat/TatwoComposerModeCard.swift');
  assert.match(card, /foregroundStyle\(filled \? LiquidGlassTokens\.browserInk : Color\.secondary\)/);
  assert.doesNotMatch(card, /foregroundStyle\(filled \? Color\.white/);
});

test('W192 I2 mode card uses conversation language without redundant explanation', () => {
  const mode = read('Chat/TatwoComposerMode.swift').replace(/\/\/[^\n]*/g, '');
  assert.doesNotMatch(mode, /"[^"\n]*session[^"\n]*"/i);
  assert.doesNotMatch(mode, /助理不帶 ultrawork（只有 Coder/);
  const uiFiles = ['Bot/BotPage.swift', 'CLI/CLISessionTree.swift', 'CLI/LoopsSessionRail.swift',
    'New/CLITranscriptHistoryView.swift', 'New/ComputerUseTarget.swift', 'New/OSOverviewPage.swift',
    'Facade/CLITranscriptArchive.swift', 'Facade/ChatPageModel+CoderImport.swift', 'Facade/ChatPageModel+Distill.swift',
    'Facade/ChatPageModel+OfflineContinue.swift', 'Facade/DistillCanvas.swift', 'Facade/BrowserStubs.swift',
    'Browser/BrowserChatSessionsSection.swift', 'Browser/BrowserManagementView.swift', 'Shell/ChatPageSettings.swift',
    'Shell/AppShell.swift', 'Shell/TatwoM3PrototypeViews.swift', 'Model/ChatSession.swift', 'Display/DisplayDiscovery.swift'];
  for (const path of uiFiles) {
    const literals = read(path).split('\n').filter(line => !line.trim().startsWith('//'))
      .flatMap(line => [...line.matchAll(/"(?:[^"\\]|\\.)*"/g)].map(m => m[0].replace(/\\\([^)]*\)/g, '')))
      .filter(literal => /[\u4e00-\u9fff]|bot sessions/.test(literal));
    for (const literal of literals) assert.doesNotMatch(literal, /(?<![\w/\-])sessions?(?![\w/\-])/i, `${path}: ${literal}`);
  }
});

test('W192 I3 dark override is DEBUG-only and dark evidence is rendered', () => {
  const theme = read('Visual/TatwoTheme.swift');
  assert.match(theme, /#if DEBUG\s+[\s\S]*?TATWO2_SELFTEST_DARK/);
  const scope = read('Visual/TatwoThemeSelfTest.swift');
  assert.match(scope, /static var forceDark/);
  assert.match(read('New/DisplaySettingsView.swift'), /dark\.png/);
  assert.match(read('Chat/AcceptanceUIFixes.swift'), /dark\.png/);
  assert.match(read('DM/GlobalDMAcceptance.swift'), /dark\.png/);
});

test('W192 I2 CLI capability chip presents conversation labels while retaining protocol IDs', () => {
  const chip = read('Chat/ChatPageLeafViews+StatusChips.swift');
  assert.match(chip, /Text\(featureTitle\)/);
  assert.match(chip, /case \.resumeSession: "續接對話"/);
  assert.match(chip, /case \.taskSidebar: "顯示對話資訊"/);
  assert.match(read('Chat/TatwoNativeCLIFeatureMap.swift'), /case resumeSession = "resume session"/);
  assert.match(read('Browser/BrowserWorkSpaceDesignView.swift'), /name: \$0\.isSessionSpace \? "對話瀏覽器" : \$0\.name/);
});
