import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const between = (s, a, b) => s.slice(s.indexOf(a), b ? s.indexOf(b, s.indexOf(a)) : undefined);

test('W255 H1: real store code uses fake Security calls only; migration preserves data and retries failures', () => {
  const vault = read('App/Sources/Tatwo2/Browser/BrowserPasswordVault.swift');
  const cf = read('App/Sources/Tatwo2/Facade/CloudflareAccounts.swift');
  const tunnel = read('App/Sources/Tatwo2/Facade/HandsGatewayLaunch.swift');
  const sources = between(vault, 'protocol BrowserSecretStore', '/// Explicitly injected') +
    between(cf, 'protocol CloudflareSecretStore', '/// 隔離環境') + between(tunnel, 'struct HandsTunnelKeychain');
  // Replace every Security entry point before compilation. No real keychain can be reached.
  const fake = sources.replace(/\bSecItem(Add|Delete|Update|CopyMatching)\b/g, 'fakeSecItem$1');
  assert.doesNotMatch(fake, /\bSec(?:Item|Keychain)\w+\b/);
  const root = mkdtempSync(join(tmpdir(), 'w255-keychain-'));
  mkdirSync(join(root, 'home'));
  const file = join(root, 'main.swift');
  writeFileSync(file, 'import Foundation\nimport Security\n' + read('tests/fixtures/w255-keychain.swift') + fake + '\ntry keychainChecks()\n');
  const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'), CLANG_MODULE_CACHE_PATH: join(root, 'cache') };
  const compile = spawnSync('/usr/bin/xcrun', ['swiftc', '-module-cache-path', join(root, 'cache'), file, '-o', join(root, 'check')], { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(compile.status, 0, compile.stdout + compile.stderr);
  const dp = spawnSync(join(root, 'check'), ['dp'], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(dp.status, 0, dp.stdout + dp.stderr);
  const run = spawnSync(join(root, 'check'), [], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W255 H1 PASS/);
});

test('W255 H2: password gate rejects spoof, iframe, unapproved fill and redirect; bound pairing needs no second confirmation', () => {
  const root = mkdtempSync(join(tmpdir(), 'w255-source-'));
  const file = join(root, 'main.cpp');
  const header = new URL('../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoAutofillSource.h', import.meta.url).pathname;
  writeFileSync(file, `#include "${header}"\n#include <cassert>\nint main() {
    const std::string allowed = "https://example.test", evil = "https://evil.test";
    assert(!TatwoAutofillAllowed(evil, allowed, true, true)); // Page's claimed origin is irrelevant.
    assert(!TatwoAutofillAllowed(allowed, allowed, false, true));
    assert(!TatwoAutofillAllowed(allowed, allowed, true, false));
    assert(!TatwoAutofillAllowed(allowed, evil, true, true));
    assert(!TatwoAutofillAllowed("", "", true, true));
    assert(TatwoAutofillAllowed(allowed, allowed, true, true));
  }`);
  const compile = spawnSync('/usr/bin/clang++', ['-std=c++17', file, '-o', join(root, 'check')], { encoding: 'utf8', timeout: 60000 });
  assert.equal(compile.status, 0, compile.stderr);
  assert.equal(spawnSync(join(root, 'check'), [], { timeout: 10000 }).status, 0);
  const mm = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const message = between(mm, 'bool W57cBrowserMessage(TatwoCEFBrowserView *view, CefRefPtr<CefFrame> frame,\n                       CefRefPtr<CefProcessMessage> message) {', '#pragma mark - W57c End');
  assert.ok(message.length > 100);
  assert.doesNotMatch(message, /args->GetString\(2\)/);
  assert.match(message, /OriginForURLString\(FromCefString\(frame->GetURL\(\)\)\)/);
  const fill = between(mm, '- (void)fillCredentialUsername:', '#pragma mark - W57c End');
  assert.match(fill, /TatwoAutofillAllowed\([\s\S]*frame->IsMain\(\), approved/);
  assert.match(fill, /autofill_refused=source_or_gesture/);
  const pod = between(read('App/Sources/Tatwo2/TAP/ChatGPTConnectorPod.swift'), '    func fillPairingCode(', '    /// 綁住的那一個畫面');
  assert.doesNotMatch(pod, /IslandNotice\.shared\.ask|要填入配對碼嗎|not_approved/);
  assert.match(pod, /guard stillBound\(\), view\.zoomLevel == 0 else \{\s*connectLog\?\.write\("pod", "autofill refused source"\)/);
  assert.match(pod, /guard let json = await Self\.snapshot\(view\)[\s\S]*guard stillBound\(\) else \{ return boundFailure\("form"\) \}[\s\S]*guard let form = Self\.pairingForm\(/);
});

test('W255 test launcher refuses Keychain and signing commands without running even a synthetic executable', () => {
  const root = mkdtempSync(join(tmpdir(), 'w255-command-'));
  const preload = new URL('./fixtures/w255-swift-plugin.mjs', import.meta.url).pathname;
  for (const name of ['security', 'codesign']) {
    const stub = join(root, name);
    writeFileSync(stub, '#!/bin/sh\necho SHOULD_NOT_RUN\n', { mode: 0o700 });
    const file = join(root, name + '.mjs');
    writeFileSync(file, `import { spawnSync } from 'node:child_process';
      import assert from 'node:assert/strict';
      const result = spawnSync(${JSON.stringify(stub)}, ['--sign', 'synthetic']);
      assert.equal(result.status, 126);
      assert.match(result.stderr, /W255_BOUNDARY/);
      assert.doesNotMatch(result.stdout, /SHOULD_NOT_RUN/);`);
    const run = spawnSync(process.execPath, ['--import', preload, file], { encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
  }
});
