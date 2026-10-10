import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = mkdtempSync(join(process.env.W301_EVIDENCE_ROOT ?? process.env.TMPDIR ?? '/tmp', 'w301-'));
const home = join(root, 'home'), live = join(root, 'live');
mkdirSync(home); mkdirSync(live);
const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, TATWO2_LIVE_ROOT: live };
const domain = `gui/${process.getuid()}`, job = `ai.tatwo.w301.fixture.${process.pid}`;
const target = `${domain}/${job}`, plist = join(home, 'Library/LaunchAgents', `${job}.plist`);
const pending = `${plist}.pending-removal`;
const run = (cmd, args, extra = {}) => spawnSync(cmd, args, { env, encoding: 'utf8', timeout: 60_000, ...extra });
const ctl = (...args) => run('/bin/launchctl', args);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, timeout = 25_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const value = check(); if (value) return value; await sleep(100); }
  assert.fail(`condition timed out; evidence: ${root}`);
}
const entries = () => existsSync(join(root, 'runs')) ? readFileSync(join(root, 'runs'), 'utf8').trim().split('\n').filter(Boolean) : [];
const pid = () => Number(entries().at(-1)?.split(' ')[0]);
const control = value => writeFileSync(join(root, 'control'), value);
const helper = join(root, 'configure');
const app = join(root, 'W301 Fixture.app'), executable = join(app, 'Contents/MacOS/fixture');
mkdirSync(join(app, 'Contents/MacOS'), { recursive: true });
const bundleID = `${job}.app`;
writeFileSync(join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>W301 Fixture</string></dict></plist>`);
const stub = 'enum TatwoSingleInstanceGuard { static func forwardToExistingInstanceAndExitIfNeeded() -> Bool { false } }';
// Both binaries compile the actual product code; only the unrelated single-instance dependency is stubbed.
writeFileSync(join(root, 'fixture.swift'), `
import AppKit
${stub}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    CrashRelaunch.willTerminate(home: URL(fileURLWithPath: ${JSON.stringify(home)}), domain: ${JSON.stringify(domain)}, job: ${JSON.stringify(job)})
  }
}
@main struct Fixture {
  @MainActor static func main() {
    let root = ${JSON.stringify(root)}
    precondition(ProcessInfo.processInfo.environment["HOME"] == root + "/home")
    precondition(ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"] == root + "/live")
    let app = NSApplication.shared; let delegate = Delegate(); app.delegate = delegate
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 260, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "W301 isolated fixture"; window.makeKeyAndOrderFront(nil)
    let pending = FileManager.default.fileExists(atPath: ${JSON.stringify(pending)})
    let line = "\\(getpid()) \\(Date().timeIntervalSince1970) \\(app.activationPolicy().rawValue) \\(pending)\\n"
    let path = root + "/runs"
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    let file = FileHandle(forWritingAtPath: path)!; file.seekToEndOfFile(); file.write(line.data(using: .utf8)!); file.closeFile()
    let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let submenu = NSMenu(); item.submenu = submenu
    submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); app.mainMenu = menu
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      let control = try? String(contentsOfFile: root + "/control", encoding: .utf8)
      if control == "off" {
        try! "run".write(toFile: root + "/control", atomically: true, encoding: .utf8)
        try! CrashRelaunch.configure(enabled: false, executable: URL(fileURLWithPath: ${JSON.stringify(executable)}), home: URL(fileURLWithPath: root + "/home"), domain: ${JSON.stringify(domain)}, job: ${JSON.stringify(job)})
      }
      if control == "quit" { try! "run".write(toFile: root + "/control", atomically: true, encoding: .utf8); app.terminate(nil) }
    }
    withExtendedLifetime((delegate, window)) { app.run() }
  }
}
`);
writeFileSync(join(root, 'harness.swift'), `
import AppKit
${stub}
@main struct Harness {
  @MainActor static func main() throws {
    let a = CommandLine.arguments
    try CrashRelaunch.configure(enabled: a[1] == "true", executable: URL(fileURLWithPath: a[2]), home: URL(fileURLWithPath: a[3]), domain: a[4], job: a[5], environment: ["HOME": a[3], "CFFIXED_USER_HOME": a[3], "TATWO2_LIVE_ROOT": a[6]])
  }
}
`);
function configure(value) {
  const result = run(helper, [String(value), executable, home, domain, job, live], { stdio: ['ignore', 'ignore', 'ignore'] });
  assert.equal(result.status, 0);
}
async function off() {
  const running = pid(), count = entries().length;
  control('off');
  await until(() => existsSync(pending) && !existsSync(plist));
  await sleep(1500);
  assert.equal(pid(), running);
  assert.equal(entries().length, count);
  assert.doesNotThrow(() => process.kill(running, 0));
  assert.equal(ctl('print', target).status, 0, 'off must keep the loaded job until normal termination');
}
async function removed(count) {
  control('quit');
  await until(() => ctl('print', target).status !== 0);
  assert.equal(existsSync(pending), false, 'normal termination clears the persistent marker');
  await until(() => run('/bin/kill', ['-0', String(pid())]).status !== 0);
  await sleep(11_000);
  assert.equal(entries().length, count, 'bootout must neither reopen nor restart the application');
}

test('W301 production code and real launchd GUI lifecycle (isolated HOME/LIVE_ROOT)', { timeout: 180_000 }, async t => {
  for (const [input, output] of [[join(root, 'fixture.swift'), executable], [join(root, 'harness.swift'), helper]]) {
    const result = run('swiftc', ['-parse-as-library', resolve('App/Sources/Tatwo2/New/CrashRelaunch.swift'), input, '-o', output]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
  }
  if (ctl('print', domain).status !== 0) {
    t.skip('GUI launchd domain unavailable; no launchd substitute counted as PASS'); return;
  }
  const evidence = [];
  try {
    configure(true);
    await until(() => entries().length === 1);
    const parsed = run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist]);
    assert.equal(parsed.status, 0, parsed.stderr);
    const config = JSON.parse(parsed.stdout);
    assert.equal(config.Program, executable);
    assert.deepEqual(config.KeepAlive, { SuccessfulExit: false });
    assert.equal(config.ThrottleInterval, 10);
    assert.equal(config.AbandonProcessGroup, true);
    assert.equal(config.EnvironmentVariables.HOME, home);
    assert.equal(config.EnvironmentVariables.TATWO2_LIVE_ROOT, live);
    assert.equal(config.LimitLoadToSessionType, 'Aqua');
    assert.equal(entries()[0].split(' ')[2], '0');
    const lsappinfo = run('/usr/bin/lsappinfo', ['info', '-only', 'bundleID,ApplicationType', bundleID]);
    assert.equal(lsappinfo.status, 0, lsappinfo.stderr);
    assert.match(lsappinfo.stdout, new RegExp(bundleID.replaceAll('.', '\\.')));
    assert.match(lsappinfo.stdout, /type="Foreground"/);
    configure(true); await sleep(1500);
    assert.equal(entries().length, 1, 'repeated enable must preserve one instance');
    evidence.push('plist: product code; isolated HOME/LIVE_ROOT; SuccessfulExit=false; throttle=10; GUI=Foreground; repeated enable=1 PID');
    await t.test('crash -> automatic restart', async () => {
      const killed = pid(), start = Date.now(); process.kill(killed, 'SIGKILL');
      await until(() => entries().length === 2, 60_000);
      assert.notEqual(pid(), killed); assert.ok(Date.now() - start < 60_000);
      evidence.push(`SIGKILL -> restart: ${Date.now() - start} ms`);
    });
    await t.test('normal AppKit terminate -> exit 0 without restart', async () => {
      control('quit'); await until(() => /last exit code = 0/.test(ctl('print', target).stdout));
      await sleep(11_000); assert.equal(entries().length, 2);
      evidence.push('menu/Command-Q AppKit action -> exit 0; no restart for 11 s');
    });
    configure(true); await until(() => entries().length === 3);
    await t.test('off -> same running PID -> normal termination removes job without reopening', async () => {
      await off(); await removed(3);
      evidence.push('off: plist absent; persistent marker present; same running PID; next normal termination removes job+marker; no restart for 11 s');
    });
    configure(true); await until(() => entries().length === 4);
    await t.test('enable during pending removal cancels removal and preserves one instance', async () => {
      await off(); configure(true); await until(() => existsSync(plist) && !existsSync(pending));
      await sleep(1500); assert.equal(entries().length, 4); assert.equal(ctl('print', target).status, 0);
      evidence.push('off -> on: pending marker cleared; plist restored; one running instance');
    });
    await t.test('crash during pending removal -> one restart -> next normal termination removes job', async () => {
      await off(); const killed = pid(), start = Date.now(); process.kill(killed, 'SIGKILL');
      await until(() => entries().length === 5, 60_000); assert.notEqual(pid(), killed);
      assert.equal(entries().at(-1).split(' ')[3], 'true', 'restarted App observes persisted pending removal');
      assert.equal(existsSync(plist), false); assert.equal(existsSync(pending), true);
      await sleep(1500); assert.equal(entries().length, 5);
      const elapsed = Date.now() - start; await removed(5);
      evidence.push(`pending + SIGKILL -> one restart: ${elapsed} ms; next normal termination removes job+marker; no restart for 11 s`);
    });
  } finally {
    ctl('bootout', target);
    writeFileSync(join(root, 'evidence.txt'), evidence.join('\n') + '\n');
    console.log(`W301 evidence: ${root}\n${evidence.join('\n')}`);
  }
});

test('W301 setting, cancellation, updater and termination wiring', () => {
  const main = readFileSync('App/Sources/Tatwo2/Tatwo2App.swift', 'utf8');
  assert.ok(main.indexOf('SelfTest.runIfRequested()') < main.indexOf('CrashRelaunch.launch()'));
  assert.ok(main.indexOf('wrapped.applicationWillTerminate(notification)') < main.indexOf('CrashRelaunch.willTerminate()'));
  assert.match(readFileSync('App/Sources/Tatwo2/Facade/InAppUpdater.swift', 'utf8'), /NSApp\.terminate\(nil\)/);
  assert.match(readFileSync('App/Sources/Tatwo2/Shell/AppShell.swift', 'utf8'), /guard approved else \{ CrashRelaunch\.requested = nil/);
  assert.match(readFileSync('install.sh', 'utf8'), /pgrep -x tatwo2 >\/dev\/null && fail/);
  const product = readFileSync('App/Sources/Tatwo2/New/CrashRelaunch.swift', 'utf8');
  const offChange = product.slice(product.indexOf('do { try configure(enabled: false)', product.indexOf('static func change(')), product.indexOf('static func willTerminate'));
  assert.doesNotMatch(offChange, /terminate\(|requested =/);
  const offConfigure = product.slice(product.indexOf('if !enabled {'), product.indexOf('let data ='));
  assert.doesNotMatch(offConfigure, /bootout|spawn|Process\(|open/);
  assert.match(product, /posix_spawn\(&pid, "\/bin\/launchctl"/);
  assert.match(product, /POSIX_SPAWN_SETPGROUP/);
  const settings = readFileSync('App/Sources/Tatwo2/New/DisplaySettingsView.swift', 'utf8');
  assert.match(settings, /當機會自動重開；登入時也會自動開啟 App/);
  assert.match(settings, /下次正常結束 App 後生效/);
});

test('W350 launchd script replaces stopped jobs before bootstrap and preserves running jobs', () => {
  const product = readFileSync('App/Sources/Tatwo2/New/CrashRelaunch.swift', 'utf8');
  const script = product.slice(product.indexOf('process.arguments ='));
  assert.ok(script.indexOf('while kill') < script.indexOf('pid = '));
  assert.ok(script.indexOf('pid = ') < script.indexOf('bootout'));
  assert.ok(script.indexOf('bootout') < script.indexOf('bootstrap'));
  assert.match(script, /pid = .*&& exit 0/);
  assert.match(product, /if recent.count >= 3/);
  assert.ok(product.indexOf('defaults.set(true, forKey: "crashRelaunchDisabled")') < product.indexOf('alert.messageText = "已關閉'));
});
test('W350 relaunch window pure production function', () => {
  const product = readFileSync('App/Sources/Tatwo2/New/CrashRelaunch.swift', 'utf8');
  const fn = product.slice(product.indexOf('nonisolated static func attempts'), product.indexOf('    static func launch()'));
  const file = join(root, 'window.swift');
  writeFileSync(file, 'import Foundation\nenum Window {\n' + fn + '\n}\n' + `
    assert(Window.attempts([0, 1, 119], now: 120) == [1, 119, 120])
    assert(Window.attempts([100, 110], now: 119).count == 3)
    assert(Window.attempts([0, 10], now: 130).count == 1)
    assert(Window.attempts([200], now: 100) == [100])
  `);
  const result = run('swift', [file]); assert.equal(result.status, 0, result.stdout + result.stderr);
});
