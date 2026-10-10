import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { realComposerPage } from './fixtures/w316-realmenu.mjs';
import { rendererPage, CID, settle } from './fixtures/w318-newrenderer.mjs';
import { nativeW298a } from './fixtures/w298a-native.mjs';
import { fixture } from './w185-pod-fixture.mjs';
import { backend } from './fixtures/w312-composer-picker.mjs';
import { nativeW298b } from './fixtures/w298b-native.mjs';

test('W351 same model and Power reuse selection; changed model, Power or trigger rereads', async () => {
  const p = await realComposerPage();
  const stop = async id => { p.command({ cmd: 'stop', id: 'stop-' + id, requestID: id }); await p.advance(1000); };
  const send = async (id, model, effort) => { p.send({ id, model, effort }); await p.advance(8000); await stop(id); };
  await send('ONE', 'six-t', 'six-t|standard');
  const clicks = p.trigger.clicks;
  assert.ok(clicks > 0);
  await send('TWO', 'six-t', 'six-t|standard');
  assert.equal(p.trigger.clicks, clicks);
  assert.equal(p.button.clicks, 2);
  await send('THREE', 'six-t', 'six-t|extended');
  assert.ok(p.trigger.clicks > clicks);
  const changedPower = p.trigger.clicks;
  await send('FOUR', 'five');
  assert.ok(p.trigger.clicks > changedPower);
  const changedModel = p.trigger.clicks;
  p.trigger.textContent = 'changed by webpage';
  await send('FIVE', 'five');
  assert.ok(p.trigger.clicks > changedModel);
});

test('W351 server default does not replace the Power step actually read for send caching', async () => {
  const p = fixture({ allowNetwork: true, respond: async url => Response.json(url.includes('/backend-api/models') ? backend()
    : url.includes('/settings/user') ? { settings: { last_used_model_config: { slugs: { web: 'six-p' } } } } : {}) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  const trigger = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button', 'aria-expanded': 'false', 'aria-controls': 'power-panel' });
  trigger.textContent = 'GPT-6';
  const panel = new p.Element('div', { role: 'menu', id: 'power-panel', 'aria-hidden': 'true' });
  new p.Element('div', { role: 'slider', 'aria-label': 'Power', 'aria-valuemin': '1', 'aria-valuemax': '5', 'aria-valuenow': '2', 'aria-valuetext': 'Medium' }, panel);
  trigger.onClick = () => { trigger.attrs['aria-expanded'] = trigger.attrs['aria-expanded'] === 'true' ? 'false' : 'true'; panel.attrs['aria-hidden'] = String(trigger.attrs['aria-expanded'] !== 'true'); };
  p.command({ cmd: 'models', id: 'initial' }); await p.advance(3000);
  assert.equal(p.reports.find(r => r.id === 'initial').data.current.preset, 'six-p');
  const before = trigger.clicks;
  p.send({ model: 'six-p' }); await p.advance(3000);
  assert.ok(trigger.clicks > before, 'visible Power was six-t; six-p must recheck: ' + JSON.stringify(p.reports));
});

test('W351 each tick shares nodes and reads answer innerText at most once per second', async () => {
  const rig = rendererPage({ api: 'failed', thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  let scans = 0, reads = 0;
  const query = p.doc.querySelectorAll.bind(p.doc);
  p.doc.querySelectorAll = selector => { if (selector === '[role="region"], [class*="thread-scroll-container"]') scans++; return query(selector); };
  Object.defineProperty(rig.body, 'innerText', { get() { reads++; return this.textContent; } });
  rig.body.textContent = 'A long partial answer '.repeat(10000);
  const clock = p.sandbox.Date.now();
  await p.advance(3000);
  assert.ok(scans >= 19 && scans <= 20, String(scans));
  assert.ok(reads <= 3, String(reads));
  assert.equal(p.sandbox.Date.now() - clock, 3000);
  assert.equal(p.reports.filter(r => r.kind === 'finished').length, 0);
});

test('W351 silence confirmation without an ID uses the thinking evidence already read by the tick', async () => {
  const p = fixture({ allowNetwork: true });
  let scans = 0;
  const query = p.doc.querySelectorAll.bind(p.doc), interval = p.sandbox.setInterval;
  p.doc.querySelectorAll = selector => { if (selector === '[role="region"], [class*="thread-scroll-container"]') scans++; return query(selector); };
  const perTick = [];
  p.sandbox.setInterval = (fn, ms) => interval(() => { const before = scans; fn(); if (ms === 150) perTick.push(scans - before); }, ms);
  p.button.onClick = () => p.sandbox.fetch('/backend-api/f/conversation', { method: 'POST', body: JSON.stringify({ model: 'auto', messages: [{ content: { parts: ['test'] } }] }) });
  p.send(); await p.advance(181000);
  assert.equal(p.reports.find(r => r.kind === 'failed')?.reason, 'no_progress');
  assert.ok(perTick.length > 1000);
  assert.ok(perTick.every(count => count <= 1));
});

test('W351 only production JS filters retired flat models and version groups', async () => {
  const p = fixture({ allowNetwork: true, respond: async url => Response.json(url.includes('/backend-api/models')
    ? { models: [{ slug: 'six', title: 'GPT-6' }, { slug: 'version:5.5', title: 'GPT-5.5' }, { slug: 'old', title: 'Legacy • Older' }] } : {}) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  const trigger = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button', 'data-model-slug': 'six', 'aria-expanded': 'false', 'aria-controls': 'panel' });
  trigger.textContent = 'GPT-6';
  const panel = new p.Element('div', { role: 'menu', id: 'panel' });
  for (const [id, title] of [['six', 'GPT-6'], ['version:5.5', 'GPT-5.5'], ['old', 'Legacy • Older']]) {
    new p.Element('button', { role: 'menuitem', 'data-model-slug': id }, panel).textContent = title;
  }
  trigger.onClick = () => { trigger.attrs['aria-expanded'] = trigger.attrs['aria-expanded'] === 'true' ? 'false' : 'true'; };
  p.command({ cmd: 'models', id: 'retired' }); await p.advance(4000);
  const result = p.reports.find(r => r.id === 'retired');
  assert.equal(result.ok, true); assert.deepEqual(result.data.models.map(m => m.slug), ['six']);
  const versions = await realComposerPage({ catalog: () => { const b = backend(); b.versions[0].id = '5.5'; return b; } });
  versions.command({ cmd: 'models', id: 'versions' }); await versions.advance(5000);
  const data = versions.reports.find(r => r.id === 'versions');
  assert.equal(data.ok, true); assert.equal(data.data.versions.length, 0);
  assert.ok(data.data.models.length > 0);
});

test('W351 same-length final text changes restart completion stability', async () => {
  const rig = rendererPage({ api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p); rig.complete(); await settle(p);
  await p.advance(7000);
  const replacement = rig.body.textContent.replace('第一節', '新一節');
  rig.body.textContent = replacement;
  await p.advance(8000);
  assert.equal(p.reports.filter(r => r.kind === 'finished').length, 0);
  await p.advance(3000);
  assert.equal(p.reports.filter(r => r.kind === 'finished').length, 1);
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, replacement);
});

test('W351 Swift model retry and cancellation', () => {
  const output = nativeW298a();
  for (const label of ['retry stays loading then succeeds within five seconds', 'retry stops after two failures',
    'sleep cancels retry']) assert.ok(output.includes('W298A PASS W351 ' + label), label);
});

test('W351 document writer commits only os and queues secondary approval', () => {
  const output = nativeW298a();
  for (const label of ['rule cell stays unchanged', 'document writer commits only os',
    'secondary queues approval without changing local roles']) assert.ok(output.includes('W298A PASS W351 ' + label), label);
});

test('W351 runtime check was deliberately removed to keep existing conversations attached', () => {
  const spec = readFileSync('docs/specs/298-ai-version-update/install.md', 'utf8');
  assert.match(spec, /常駐對話保留啟動時執行檔/);
  const change = spawnSync('/usr/bin/git', ['show', '0cf35c0d', '--', 'App/Sources/Tatwo2/Facade/ChatLiveEngine.swift'], { encoding: 'utf8' });
  assert.equal(change.status, 0);
  assert.match(change.stdout, /-.*startedExecutableIdentity == EnginePaths/);
  const live = readFileSync('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift', 'utf8');
  const reuse = live.slice(live.indexOf('let apiKeyOptOutMatches ='), live.indexOf('finishGoalControl(threadID', live.indexOf('let apiKeyOptOutMatches =')));
  assert.doesNotMatch(reuse, /runtimeMatches|startedExecutableIdentity/);
});

test('W351 Claude bundle without launcher gives manual update; rollback also restores launcher', () => {
  const output = nativeW298b();
  for (const label of ['missing launcher gives manual update', 'rollback launcher runs the old version'])
    assert.ok(output.includes('W298B PASS W351 ' + label), label);
});

const source = path => readFileSync('App/Sources/Tatwo2/' + path, 'utf8');
const root = mkdtempSync(join(process.env.TMPDIR ?? '/tmp', 'w351-pure-'));
for (const dir of ['home', 'live']) mkdirSync(join(root, dir));
const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'), TATWO2_LIVE_ROOT: join(root, 'live') };
function swift(name, code) {
  const file = join(root, name + '.swift'), binary = join(root, name);
  writeFileSync(file, code);
  let run = spawnSync('/usr/bin/swiftc', ['-parse-as-library', file, '-o', binary], { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 30000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
}

test('W351 cold launch URL/file events skip handoff and keep relaunch preference', () => {
  const relaunch = source('New/CrashRelaunch.swift');
  const fn = relaunch.slice(relaunch.indexOf('    nonisolated static func canHandoff'), relaunch.indexOf('    static var requested'));
  swift('launch', `import Foundation\nenum Launch {\n${fn}\n}\n@main struct Test { static func main() {
    assert(Launch.canHandoff(["app"], openEvent: false))
    assert(Launch.canHandoff(["app", "-psn_0_123"], openEvent: false))
    assert(!Launch.canHandoff(["app", "https://example.invalid"], openEvent: false))
    assert(!Launch.canHandoff(["app", "/fixture/file.txt"], openEvent: false))
    assert(!Launch.canHandoff(["app"], openEvent: true))
  } }`);
  const main = source('Tatwo2App.swift');
  assert.ok(main.indexOf('SelfTest.runIfRequested()') < main.indexOf('CrashRelaunch.launch()'));
  const didFinish = main.slice(main.indexOf('    func applicationDidFinishLaunching'), main.indexOf('    func application(_ application: NSApplication, openFile'));
  assert.match(didFinish, /CrashRelaunch\.launch\(\).*exit\(0\)/);
  assert.ok(didFinish.indexOf('CrashRelaunch.launch()') < didFinish.indexOf('wrapped.applicationDidFinishLaunching'));
  for (const signature of ['openFile filename', 'open urls']) {
    const handler = main.slice(main.indexOf(signature), main.indexOf(signature) + 190);
    assert.match(handler, /CrashRelaunch.hasLaunchTargets = true/);
  }
  assert.match(relaunch, /guard available, enabled, canHandoff\(CommandLine.arguments, openEvent: hasLaunchTargets\) else \{ return false \}/);
});

test('W351 production resource limits stop growing, slow and cancelled processes; bound download without network', () => {
  const install = source('Facade/EngineInstall.swift'), update = source('Facade/EngineAIUpdate.swift');
  const download = install.slice(install.indexOf('    nonisolated static let byteLimit'), install.indexOf('    var signature:'));
  const runner = update.slice(update.indexOf('    nonisolated static func background'), update.lastIndexOf('\n}'));
  assert.match(install, /await EngineAIUpdate.background \{ Data\(SHA512.hash/);
  assert.match(install, /EngineAIUpdate.wait\(p, output: binary, limit: Self.byteLimit, seconds: 60\)/);
  assert.doesNotMatch(runner, /Data\(contentsOf:/);
  assert.match(runner, /read\(upToCount: 1_000_001\)/);
  swift('resources', `
import Foundation
import Darwin
enum EngineInstall { ${download} }
enum EngineAIUpdate { ${runner} }
final class ProtocolFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if request.url!.path == "/hang" { return }
    let slow = request.url!.path == "/slow"
    DispatchQueue.global().async {
      for _ in 0..<8 {
        if slow { Thread.sleep(forTimeInterval: 0.04) }
        self.client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8))
      }
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}
@main struct Test {
  static func main() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProtocolFixture.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let url = URL(string: "https://registry.npmjs.org/fixture")!
    let data = try await EngineInstall.download(url, limit: 64, seconds: 2, session: session)
    assert(data.count == 64)
    do { _ = try await EngineInstall.download(url, limit: 16, session: session); assertionFailure("download overflow accepted") } catch {}
    do { _ = try await EngineInstall.download(url.appendingPathComponent("../slow").standardized, seconds: 0.08, session: session); assertionFailure("slow download accepted") } catch {}
    let task = Task { try await EngineInstall.download(URL(string: "https://registry.npmjs.org/hang")!, session: session) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    do { _ = try await task.value; assertionFailure("cancelled download accepted") } catch {}
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!)
    let output = home.appendingPathComponent("output"), pidFile = home.appendingPathComponent("pid")
    func checkProcess(_ script: String, limit: Int, seconds: Double, cancel: Bool = false) async throws {
      try Data().write(to: output)
      let job = Task { try await EngineAIUpdate.background {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]; p.environment = ["HOME": home.path, "TATWO2_LIVE_ROOT": ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"]!]
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        p.standardOutput = handle; p.standardError = FileHandle.nullDevice
        try p.run(); try String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        try EngineAIUpdate.wait(p, output: output, limit: limit, seconds: seconds)
      } }
      if cancel { try await Task.sleep(for: .milliseconds(80)); job.cancel() }
      let start = Date()
      do { _ = try await job.value; assertionFailure("process limit accepted") } catch {}
      assert(Date().timeIntervalSince(start) < 2)
      let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
      assert(kill(pid, 0) != 0)
    }
    try await checkProcess("while :; do printf '12345678901234567890123456789012'; done", limit: 1024, seconds: 10)
    try await checkProcess("trap '' TERM; while :; do :; done", limit: 1024, seconds: 0.08)
    try await checkProcess("while :; do :; done", limit: 1024, seconds: 10, cancel: true)
    let script = home.appendingPathComponent("command")
    try "#!/bin/sh\\nprintf '1.2.3'\\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let result = await EngineAIUpdate.command(script, [], home: home)
    assert(result == "1.2.3")
    try "#!/bin/sh\\nexit 0\\n".write(to: script, atomically: true, encoding: .utf8)
    let empty = await EngineAIUpdate.command(script, [], home: home)
    assert(empty == "")
  }
}`);
});
