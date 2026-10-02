// Run after: swift build --product Tatwo2
// Uses the built app's production views and event handlers with synthetic data.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const binary = fs.realpathSync('.build/debug/Tatwo2');
const root = testScratch('tw-app-');
const cleanEnv = { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR ?? '/tmp' };
function run(name, extra) {
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, 'home'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'fixture-only'), '');
  const env = {
    ...cleanEnv, HOME: path.join(dir, 'home'), CFFIXED_USER_HOME: path.join(dir, 'home'),
    TATWO2_ISSUE_TEST_ROOT: dir, TATWO2_LIVE_ROOT: path.join(dir, 'live'),
    TATWO2_ENGINES_ROOT: path.join(dir, 'engines'), TATWO2_OS_ROOT: path.join(dir, 'os'),
    TATWO2_OS_SOCKET: path.join(dir, 'os.sock'), TATWO2_BROWSER_SOCKET: path.join(dir, 'browser.sock'),
    // These fixture runs never start the production bridge sockets or load credentials.
    ...extra,
  };
  const result = spawnSync(binary, [], { cwd: dir, env, encoding: 'utf8', timeout: 90_000 });
  fs.writeFileSync(path.join(dir, 'run.log'), result.stdout + result.stderr);
  assert.equal(result.status, 0, name + ': ' + result.stdout + result.stderr);
  return { dir, output: result.stdout };
}
for (const engine of ['claude', 'codex']) {
  const result = run(engine, { TATWO2_CHATSTEERINGTEST: '1', TATWO2_CHATSTEERING_ENGINE: engine });
  assert.match(result.output, /RESULT passed=\d+ failed=0 skipped=0/);
  console.log(engine, result.output.match(/RESULT .*/)[0]);
}
for (const [name, flag] of [['lifecycle', 'TATWO2_TURNLIFECYCLETEST'], ['stream', 'TATWO2_STREAMAPPENDTEST']]) {
  const result = run(name, { [flag]: '1' });
  assert.match(result.output, /RESULT passed=\d+ failed=0 skipped=0/);
  console.log(name, result.output.match(/RESULT .*/)[0]);
}
for (const theme of ['aurora', 'fable5']) {
  const name = `${theme}-cycle`;
  const result = run(name, {
    TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT: path.join(root, name, 'window.png'),
    TATWO_ULTRAWORK_EXPORT_TAB: 'chat', TATWO_ULTRAWORK_EXPORT_CHAT_SCENE: 'send',
    TATWO_ULTRAWORK_EXPORT_CHAT_PROMPT: '驗收輸入文字：日夜切換後仍可讀。',
    TATWO_ULTRAWORK_THEME: theme, TATWO_ULTRAWORK_EXPORT_APPEARANCE: 'cycle',
    TATWO_ULTRAWORK_EXPORT_WIDTH: '1280', TATWO_ULTRAWORK_EXPORT_HEIGHT: '900',
    TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS: '800', TATWO_ULTRAWORK_CHAT_RAIL_PINNED: '1',
  });
  const png = index => fs.readFileSync(path.join(result.dir, `window.${index}.png`));
  assert.deepEqual(png(0), png(2), `${theme}: returning to day must restore the complete rendered view`);
  assert.notDeepEqual(png(0), png(1), `${theme}: night must redraw the retained view`);
  console.log(theme, 'PASS full window light/dark/light cycle');
}
console.log('APP_ACCEPTANCE_EVIDENCE', root);
