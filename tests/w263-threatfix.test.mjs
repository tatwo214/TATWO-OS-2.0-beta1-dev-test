import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const section = (source, start, end) => {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, start);
  return source.slice(a, b);
};
let fixture;
function probe(mode) {
  if (!fixture) {
    const root = mkdtempSync(join(tmpdir(), 'w263-'));
    const home = join(root, 'hermes-home');
    for (const path of ['x/trading/proj', 'Hermes/a/b', 'tradingcard-notes', 'plain/proj']) {
      mkdirSync(join(home, path), { recursive: true });
    }
    mkdirSync(join(root, 'BTC', 'a', 'b'), { recursive: true });
    symlinkSync(join(home, 'Hermes/a/b'), join(home, 'plain/shortcut'));
    symlinkSync(join(home, 'plain/proj'), join(home, 'trading-shortcut'));
    const floors = read('App/Sources/Tatwo2/Facade/HandsFloors.swift');
    const sandbox = read('App/Sources/Tatwo2/Facade/HandsSandbox.swift');
    const config = read('App/Sources/Tatwo2/Facade/HandsBuildConfig.swift');
    // Compile the production classifier, realpath and raiseCheck; only their surrounding data types are fixtures.
    const source = 'import Foundation\nimport Darwin\n' +
      section(sandbox, 'enum HandsPath {', '    static func isWithin') + '}\n' +
      section(floors, 'enum HandsTradingFloor {', '\nextension HandsProjectChoice') + `
enum HandsBuildRaise { case unknown, needsUpdate, allowed }
struct HandsBuildDeviceReport { var receivedAt: Date?; var levelGuard = true; var appliedConfigRevision = 7 }
struct HandsBuildConfig {
  var configRevision = 7
` + section(config, '    static let raiseReportWindow:', '\n    func entry(') + `
}
let home = FileManager.default.homeDirectoryForCurrentUser.path
precondition(home == CommandLine.arguments[2], "fixture HOME must be isolated")
let mode = CommandLine.arguments[1]
func trading(_ path: String, name: String = "plain") -> Bool {
  HandsTradingFloor.isTrading(name: name, folder: home + "/" + path)
}
let now = Date(timeIntervalSince1970: 1000)
func raised(_ age: Double?, guardEnabled: Bool = true, revision: Int = 7) -> HandsBuildRaise {
  HandsBuildConfig.raiseCheck(HandsBuildDeviceReport(receivedAt: age.map { now.addingTimeInterval(-$0) },
    levelGuard: guardEnabled, appliedConfigRevision: revision), config: HandsBuildConfig(), now: now)
}
switch mode {
case "ancestors":
  precondition(trading("x/trading/proj"))
  precondition(trading("Hermes/a/b"))
  precondition(HandsTradingFloor.isTrading(name: "fixture", folder: CommandLine.arguments[3] + "/BTC/a/b"))
case "symlinks":
  precondition(trading("plain/shortcut"))
  precondition(trading("trading-shortcut"))
  let normal = UUID(), shortcut = UUID()
  precondition(HandsTradingFloor.classify([(normal, "plain", home + "/plain/proj"),
    (shortcut, "plain", home + "/trading-shortcut")]) == [normal.uuidString, shortcut.uuidString])
case "substring":
  precondition(trading("tradingcard-notes"))
  precondition(trading("plain/proj", name: "BTC notes"))
  precondition(!trading("plain/proj"), "home name hermes-home must not classify descendants")
  precondition(!trading("plain/Hermetic/a"))
case "fresh":
  for age in [0.0, 1, 44.999, 45] { precondition(raised(age) == .allowed) }
case "stale":
  for age in [-0.001, -1, -45, -46, 45.001, 46, Double.infinity, -Double.infinity, Double.nan] {
    precondition(raised(age) == .unknown)
  }
  precondition(raised(nil) == .unknown)
  precondition(HandsBuildConfig.raiseCheck(nil, config: HandsBuildConfig(), now: now) == .unknown)
case "guards":
  precondition(raised(0, guardEnabled: false) == .needsUpdate)
  precondition(raised(0, revision: 6) == .unknown)
  precondition(raised(0, revision: 8) == .allowed)
default: preconditionFailure("unknown fixture mode")
}
print("W263 " + mode + " PASS")
`;
    const file = join(root, 'main.swift'), binary = join(root, 'probe');
    writeFileSync(file, source);
    const env = { PATH: process.env.PATH, HOME: home, CFFIXED_USER_HOME: home, TMPDIR: root,
      CLANG_MODULE_CACHE_PATH: join(root, 'cache') };
    const compile = spawnSync('/usr/bin/xcrun', ['swiftc', '-module-cache-path', join(root, 'cache'), file, '-o', binary],
      { env, encoding: 'utf8', timeout: 60_000 });
    assert.equal(compile.status, 0, compile.stdout + compile.stderr);
    fixture = { root, home, binary, env };
  }
  const run = spawnSync(fixture.binary, [mode, fixture.home, fixture.root], { env: fixture.env, encoding: 'utf8', timeout: 10_000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, new RegExp('W263 ' + mode + ' PASS'));
}

test('W263 F1: nested trading/Hermes ancestors and paths outside HOME are read-only', () => probe('ancestors'));
test('W263 F1: neutral symlink resolves trading ancestors; configured aliases share the floor', () => probe('symlinks'));
test('W263 F1: tradingcard-notes retains substring matching; HOME and ordinary names are excluded', () => probe('substring'));
test('W263 F2: report ages 0 through 45 seconds are allowed', () => probe('fresh'));
test('W263 F2: future, expired, missing and nonfinite timestamps are refused', () => probe('stale'));
test('W263 F2: levelGuard and applied revision checks remain required', () => probe('guards'));
