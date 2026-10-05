import test from 'node:test';
import { nativeW214 } from './w214-native-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import './w171-setup-in-settings.test.mjs';

const read = file => readFileSync(new URL('../App/Sources/Tatwo2/' + file, import.meta.url), 'utf8');

test('W190 first setup step combines assistant model selection and login', () => {
  const guide = read('Shell/SetupGuide.swift');
  assert.match(guide, /next\.append\(Self\.assistantItem/);
  assert.match(guide, /title: "設定 TATWO 助理模型"/);
  assert.doesNotMatch(guide, /"登入一個 AI 模型"/);
  assert.match(guide, /TATWO 助理熟悉這套 OS 和你，幫你處理設定、設備、記憶和派工。先選它用哪個模型。/);
  assert.match(guide, /!loggedIn \? \.todo : model\?\.isExplicit == true \? \.done : \.defaulted/);
  assert.match(guide, /"已選：\\\(name\)" : "目前：\\\(name\)"/);
  assert.match(nativeW214(2), /W214 PASS N2.setup-login-renamed-in-tree/);
  assert.match(nativeW214(2), /W214 PASS N2.setup-login-routes-to-login/);
  assert.match(guide, /state: state, section: \.modelAccess, required: true/);
  assert.match(guide, /AssistantModelMenu\(model: model\)/);
  assert.doesNotMatch(guide, /borderedProminent|Color\.accentColor|\.blue\b|confirmationDialog|sheet\(/);
  const steps = [...guide.matchAll(/next\.append\(Item\(id: "([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(steps, ['rules', 'memory', 'device', 'backup', 'media', 'spotify', 'computer']);
});

test('W190 setup and composer use the same options, setter, current model and updates', () => {
  const menu = read('Assistant/AssistantModelMenu.swift');
  assert.match(menu, /Self\.popUp\(Self\.menu\(for: model\), above: view\)/);
  assert.match(menu, /makeMenu\(primaryName: model\.assistantPrimaryName, options: model\.assistantModelOptions\)/);
  assert.match(menu, /model\.setAssistantModel\(id\)/);
  assert.match(menu, /title: assistantModelChipTitle/);
  const guide = read('Shell/SetupGuide.swift');
  assert.match(guide, /\.onChange\(of: model\.assistantSetupModel\)/);
  assert.match(guide, /\.onChange\(of: model\.engineLogins\)/);
  assert.match(guide, /assistantModel: model\.assistantSetupModel/);
  assert.match(menu, /ChatComposerModelLabel\(title: title/);
  assert.match(menu, /\.disabled\(model\.assistantIsRunning\)/);
});

test('W190 assistant introduction and actual packaged preamble describe OS and user familiarity', () => {
  assert.match(read('Assistant/AssistantSpacePane.swift'), /我熟悉 TATWO OS 和你，幫你處理設定、設備、記憶和派工協調。/);
  const persona = read('Resources/tatwo-assistant.md');
  assert.match(persona, /熟悉 TATWO OS 與使用者/);
  assert.match(persona, /設定、設備、記憶、派工協調/);
  assert.doesNotMatch(persona, /專案\s*bot|project bot/i);
  const baseline = spawnSync('git', ['show', '4443f453:App/Sources/Tatwo2/Resources/tatwo-assistant.md'], {
    cwd: new URL('../', import.meta.url), encoding: 'utf8',
  });
  assert.equal(baseline.status, 0, baseline.stderr);
  const duties = source => source.slice(source.indexOf('## 你做什麼'));
  // W192 的用語調整與 W194 #7 的三處多餘空格以外，職責與安全段落仍逐字比對。
  const currentTerms = baseline.stdout
    .replaceAll('某條 session', '某條對話').replaceAll('哪條 session', '哪條對話')
    .replaceAll('專案與 session', '專案與對話').replaceAll('那條 session', '那條對話')
    .replaceAll('一條 session', '一條對話').replaceAll('TAP › ChatGPT', '設定 › ChatGPT 手腳')
    .replace('等級（L0／L1／L2）與允許的專案由使用者在 設定 › ChatGPT 手腳 決定。',
      '連上＝全開，不提供 L0／L1／L2 等級選擇；需要使用者核准的操作仍在 Island 確認。')
    .replaceAll('設定 › ChatGPT 手腳', '設定 › Plugin › TAP 的 ChatGPT build')
    .replace('## ChatGPT 手腳標準流程', '## ChatGPT build 標準流程')
    .replace('要開「ChatGPT 手腳」', '要開「ChatGPT build」')
    .replace('副設備的 設定', '副設備的設定')
    .replace('到 環境登入', '到環境登入')
    .replace('某條對話 時', '某條對話時')
    .replace('那條對話 的輸入框', '那條對話的輸入框')
    .replace('一條對話 做完後', '一條對話做完後');
  assert.equal(duties(persona), duties(currentTerms), 'only W192 wording and W194 #7 whitespace fixes change; other duties and safeguards stay exact');
  assert.match(persona, /連上＝全開/);
  assert.doesNotMatch(persona, /session|TAP › ChatGPT|等級（L0／L1／L2）與允許的專案由使用者/);
});

test('W190 isolated self-test renders three real setup pages and exercises real menu selection', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w190setup"/);
  const guide = read('Shell/SetupGuide.swift');
  for (const marker of ['NativeStagingIsolation.validationError', 'no-login', 'logged-in-default', 'model-selected',
    'TatwoComposerModeAcceptance.ClickRig', 'setup-assistant-login', 'NSApp.sendAction', 'selection updates the open setup row immediately',
    'actual assistant composer chip uses the selected name', 'assistant model choice survives reopening',
    'assistant preamble describes OS and user familiarity', 'W190SETUP SUMMARY passed=']) {
    assert.ok(guide.includes(marker), marker);
  }
});
