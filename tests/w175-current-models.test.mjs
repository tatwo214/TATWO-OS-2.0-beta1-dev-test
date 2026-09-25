// W175（使用者 2026-09-23）：「兩台設備的 os app 裡面的模型只留 gpt5.6 以上 opus5.5 sonnet5 fable5.1 grok4.7 等最新的模型」
// 選單只列現役模型；舊討論串存的舊模型 ID 改走接替的新模型，不 fail closed。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const catalog = read('App/Sources/Tatwo2/Chat/TatwoChatRouteProfile.swift');

test('W175 picker lists only current models', () => {
  const block = catalog.slice(catalog.indexOf('public static let defaults'), catalog.indexOf('private static func normalizedLookupKey'));
  const ids = [...block.matchAll(/\n      id: "([^"]+)",/g)].map((m) => m[1]);
  assert.deepEqual(ids, ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-6-astra', 'grok-build', 'fable5.1', 'sonnet5', 'opus5.5', 'codex-auto-review']);
  assert.match(block, /displayName: "Grok 4\.7",[\s\S]{0,200}modelArgument: "grok-4\.7"/);
  assert.match(block, /id: "opus5\.5",[\s\S]{0,300}modelArgument: "claude-opus-5-5"/);
  for (const retired of ['"gpt-5.5"', '"gpt-5.4"', '"claude-fable-5"', '"haiku-4-5"', '"minimax-m3"', '"grok-4.6"', 'modelArgument: "opus"']) {
    assert.ok(!block.includes(retired), 'retired model still in picker: ' + retired);
  }
});

test('W175 retired IDs resolve to their replacements', () => {
  const map = catalog.slice(catalog.indexOf('static let retiredReplacements'), catalog.indexOf('public static func resolve'));
  for (const [oldKey, newKey] of [['gpt55', 'gpt56sol'], ['gpt54', 'gpt56sol'], ['fable5', 'fable51'], ['haiku45', 'sonnet5'],
    ['opus5', 'opus55'], ['minimaxm3', 'gpt56luna'], ['grok46', 'grokbuild']]) {
    assert.ok(map.includes(`"${oldKey}": "${newKey}"`), oldKey);
  }
  assert.match(catalog, /"opus": "opus55",\n    \]\.merging\(retiredReplacements\)/);
});

test('W175 built-in Claude engine can reach Opus 5.5; roles follow constitution §4', () => {
  const pkg = JSON.parse(read('Engines/claude-sidecar/package.json'));
  assert.equal(pkg.dependencies['@anthropic-ai/claude-agent-sdk'], '0.3.280', 'Opus 5.5 needs Claude Code 2.1.280+');
  const lock = JSON.parse(read('Engines/claude-sidecar/package-lock.json'));
  assert.equal(lock.packages['node_modules/@anthropic-ai/claude-agent-sdk'].version, '0.3.280');
  assert.match(read('App/Sources/Tatwo2/Chat/UltraworkRoleConfiguration.swift'), /refinement: "opus-5\.5",/);
  const os = read('App/Sources/Tatwo2/Resources/os.md');
  assert.match(os, /\| 細修 \| Opus 5\.5 \|/);
  assert.match(os, /\| 機械工 \| Grok 4\.7 \|/);
  assert.match(read('App/Sources/Tatwo2/Facade/ChatPageModel.swift'), /@Published var selectedModel = "gpt-6-astra"/);
});
