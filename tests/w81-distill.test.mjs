import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import readline from 'node:readline';
import { once } from 'node:events';
import { StdioTransport } from '../Engines/gbrain-adapter/server.mjs';
import { delay } from '../Engines/gbrain-adapter/service.mjs';
import { resolveBinary, resolveGBrainHelper } from './helpers/app-binary.mjs';

const read = file => fs.readFileSync(new URL(`../App/Sources/Tatwo2/${file}`, import.meta.url), 'utf8');
// W180 E4：建好的 App 與 GBrain helper 也可以從主設備 staging 找到（lead-verify 的 node 步驟沒帶環境變數）。
// 找不到就明確失敗，不跳過（整批驗收不能變成跳過）。
const binary = resolveBinary();
const headings = ['這段做了什麼', '架構現況', '決策與理由', '教訓', '下一步'];
const finalBody = headings.map(title => `## ${title}\n使用者改過這一句，保留　空白、兩個空格  、Cafe\u0301 與 emoji 🧪。`).join('\n\n');
function fixture() {
  const root = fs.mkdtempSync(path.join(tmpdir(), 'w81-'));
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e', 'entry', 'docs']) fs.mkdirSync(at(name));
  fs.writeFileSync(at('owned-fixture'), 'synthetic W81 fixture only\n');
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    TATWO2_W81_TEST_ROOT: root, TATWO2_SOURCETEST: '1',
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'),
    TATWO2_LIVE_ROOT: at('l'), TATWO2_ENGINES_ROOT: at('e'),
    CODEX_HOME: at('e/codex'), TATWO2_CODEX_SOURCE_HOME: at('e/codex'),
    CLAUDE_CONFIG_DIR: at('e/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('e/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO_OS_ROOT: at('entry'), TATWO2_OS_ROOT: at('entry'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('docs/os-upstream.md'), TATWO2_SKILLET_PATH: at('entry/skillet.md'),
  };
  return { root, at, env };
}
function run(env) {
  assert.ok(binary && fs.existsSync(binary), 'Set TATWO2_TEST_BINARY (or run inside the staging build worktree); never skip.');
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 150_000, maxBuffer: 2 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  assert.match(output, /W81TEST SUMMARY failures=0/);
  console.log(output.split('\n').filter(line => line.startsWith('W81TEST')).join('\n'));
  return output;
}

test('W81 production Swift: draft, repeated rewrite, exact edits, human boundary, cancel/reopen, guards (W180 E4 canvas)',
  { timeout: 180_000 }, () => {
    const { env } = fixture();
    const output = run(env);
    for (const name of [
      'exact-command-token', 'bare-command-opens-canvas', 'argument-command-opens-canvas', 'ai-draft-exact',
      'ai-multiple-rewrites', 'nested-fence-preserved', 'example-and-incomplete-fence-ignored',
      'legacy-fence-only-for-old-canvas', 'human-edit-byte-exact', 'raw-json-roundtrip',
      'ordinary-confirm-cannot-submit', 'close-reopen-no-write', 'unavailable-gbrain-rejected',
      'gbrain-normalization-rejected', 'unicode-byte-not-canonical-equality', 'stale-snapshot-rejected',
      'human-submit-boundary', 'submitted-edit-blocked', 'submission-survives-reopen-no-rewrite',
      'repeat-submission-rejected', 'legacy-canvas-still-reads', 'skillet-untouched',
    ]) assert.ok(output.includes(`W81TEST PASS ${name}\n`), name);
  });

// W180 E4：skillet 整份覆蓋、GBrain／skillet 開關、「送出」按鈕都已拿掉（改成整理成技能等、預覽寫入→確認寫入）。
test('W81 canvas contract after W180 E4: no skillet destination, no toggles, only the human confirm writes', () => {
  const canvas = read('Facade/DistillCanvas.swift');
  const actions = read('Chat/DistillPlanActions.swift');
  const panel = read('Chat/ChatPage+Plan.swift');
  const engine = read('Facade/ChatLiveEngine+Plan.swift');
  for (const source of [canvas, actions]) {
    assert.doesNotMatch(source, /Toggle\("GBrain"|Toggle\("skillet"|@State private var skillet|writeFromDevice\(id: "skillet"/);
    assert.doesNotMatch(source, /Button\(busy \? "送出中…" : "送出"\)|inbox_receive|pushSubmission/);
  }
  assert.match(actions, /chip\(busy \? "寫入中…" : "確認寫入", selected: true\) \{ runWrite\(\) \}/);
  assert.match(panel, /artifact.kind == "distill"[\s\S]*DistillPlanActions/);
  assert.match(engine, /plan.kind == "distill"[\s\S]*Self.distillDiscussionRules\(for: DistillCanvas.output\(of: plan\)\)/);
  assert.match(read('Chat/ChatPage.swift'), /distillActions: model.distillCanvasActions/);
  // W78 的 skillet 提案檢查隨 skillet 去處一起退役。
  const selftest = read('SelfTest.swift');
  assert.doesNotMatch(selftest, /check\("w81-proposal-in-primary-inbox"|DistillCanvas\.writeSkillet/);
  // 真 GBrain 往返走正式路徑（畫布 → 預覽 → DistillHost.begin → DistillWriter.perform → finish），不再有只給測試用的包裝。
  const gbrain = selftest.slice(selftest.indexOf('TATWO2_W81_GBRAIN_DEFINITION'), selftest.indexOf('W81TEST GBRAIN_SLUG'));
  for (const call of ['DistillHost.preview(', 'DistillHost.begin(apply', 'DistillWriter.perform(job)', 'DistillHost.finish(job',
    'DistillHost.begin(restore', 'DistillWriter.readManifest(']) assert.ok(gbrain.includes(call), call);
  assert.doesNotMatch(canvas + selftest, /DistillGBrainClient\.write\(|DistillCanvas\.validate\(|static func validate\(_ submission/);
  assert.ok(canvas.includes('"clientInfo"') && canvas.includes('"tatwo-distill"'), 'same MCP client identity');
  // 同名舊頁：只有 GBrain 明確回 page_not_found 才算新建；其他錯誤、讀不出內容都不寫。整頁（含標題、tags）進封存。
  assert.match(canvas, /"include_content": true/);
  assert.match(canvas, /object\["error"\] as\? String == "page_not_found"/);
  assert.doesNotMatch(canvas, /try\? call\("get_page"/);
  const writer = read('Facade/DistillWriter.swift');
  assert.match(writer, /gbrain-page\.json/);
  assert.match(writer, /catch let notSent as DistillGBrainClient\.NotSent/);
});

test('W81 real GBrain (W180 E4 production path): archive same-slug page whole → write → refuse changed page → restore old page + title',
  { timeout: 240_000 }, async () => {
    // W180 E4：GBrain 仍是 /蒸餾 的選項之一；這條往返保留，缺 helper 就失敗（不跳過）。
    const helper = resolveGBrainHelper();
    assert.ok(helper && fs.existsSync(helper), 'W80B_GBRAIN_HELPER is required (or run inside the staging build worktree); never skip.');
    const { root, at, env } = fixture();
    const ownerRoot = at('brain-owner'); fs.mkdirSync(ownerRoot);
    fs.writeFileSync(path.join(ownerRoot, 'device.json'), JSON.stringify({ role: 'primary', name: 'fixture-device' }));
    fs.writeFileSync(at('gbrain-draft.txt'), finalBody);
    const supervisor = path.resolve('Engines/gbrain-adapter/service.mjs');
    const adapter = path.resolve('Engines/gbrain-adapter/server.mjs');
    const owner = spawn(process.execPath, [supervisor, ownerRoot, helper],
      { env: { PATH: env.PATH, TMPDIR: env.TMPDIR, HOME: env.HOME }, stdio: ['pipe', 'pipe', 'pipe'] });
    let token, diagnostics = '', client;
    owner.stderr.on('data', data => { diagnostics += data; });
    readline.createInterface({ input: owner.stdout }).on('line', line => {
      const event = JSON.parse(line);
      if (event.token) { token = event.token; owner.stdin.write('stored\n'); }
    });
    try {
      let state;
      for (let i = 0; i < 180; i++) {
        assert.equal(owner.exitCode, null, `isolated owner exited: ${diagnostics}`);
        try { state = JSON.parse(fs.readFileSync(path.join(ownerRoot, 'gbrain/state.json'))); } catch {}
        if (state?.healthy && token) break;
        await delay(500);
      }
      assert.equal(state?.healthy, true, diagnostics);
      const output = run({ ...env, TATWO_GBRAIN_TOKEN: token,
        TATWO2_W81_GBRAIN_DEFINITION: JSON.stringify({ command: process.execPath, args: [adapter, ownerRoot] }) });
      for (const name of ['real-gbrain-production-write', 'real-gbrain-old-page-archived-whole', 'real-gbrain-restore-refuses-changed-page',
        'real-gbrain-restore-puts-old-page-back', 'real-gbrain-written-page-kept-in-archive']) {
        assert.ok(output.includes(`W81TEST PASS ${name}\n`), name);
      }
      const slug = output.match(/^W81TEST GBRAIN_SLUG (\S+)$/m)?.[1];
      assert.ok(slug && slug.startsWith('distill/'), 'slug printed');
      client = new StdioTransport(process.execPath, [adapter, ownerRoot], { ...env, TATWO_GBRAIN_TOKEN: token });
      await client.request({ jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } } });
      await client.request({ jsonrpc: '2.0', method: 'notifications/initialized' });
      // 還原之後 GBrain 上是舊頁：正文、標題逐字放回，設備來源照樣由 adapter 蓋上。
      const readback = await client.request({ jsonrpc: '2.0', id: 2, method: 'tools/call',
        params: { name: 'get_page', arguments: { slug } } });
      assert.ok(!readback.error && !readback.result?.isError, JSON.stringify(readback));
      const page = readback.result.structuredContent ??
        JSON.parse(readback.result.content.find(row => row.type === 'text').text);
      assert.equal(page.compiled_truth, '# Old synthetic page\nold body line　保留 🧪');
      assert.equal(page.title, 'Old synthetic title');
      assert.equal(page.frontmatter.device, 'fixture-device');
      assert.ok(page.tags.includes('device:fixture-device'));
      fs.writeFileSync(at('roundtrip-evidence.json'), JSON.stringify({ slug: page.slug, restoredOldPage: true,
        device: page.frontmatter.device, bytes: Buffer.byteLength(finalBody) }, null, 2));
      console.log(`W81 real roundtrip evidence: ${root}`);
    } finally {
      client?.close();
      if (owner.exitCode === null && owner.signalCode === null) {
        const exited = once(owner, 'exit');
        const timer = setTimeout(() => owner.kill('SIGKILL'), 10_000);
        owner.stdin.end(); owner.kill('SIGTERM');
        try { await exited; } finally { clearTimeout(timer); }
      }
    }
  });
