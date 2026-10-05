import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
test('native Quit confirms before synchronous CLI save/detach/finish, preserving bypass', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/termination-repair'); fs.mkdirSync(dir, {recursive: true});
  const app = read('App/Sources/Tatwo2/Tatwo2App.swift');
  const delegate = app.slice(app.indexOf('@MainActor private final class Tatwo2CLITerminationDelegate'));
  const events = `
@MainActor enum OSEventLog {
    static var flushCalls = 0
    static func flushAll() {
        precondition(CLISessionsTermination.events == ["save", "detach", "finishWrites"])
        precondition(flushCalls == 0)
        flushCalls += 1
        print("PASS: event flush follows CLI persistence exactly once")
    }
}
`;
  const source = read('App/Sources/Tatwo2/Shell/TatwoTerminationCoordinator.swift') + '\n' + events + delegate + '\n' + read('tests/fixtures/browser-termination-checks.swift');
  fs.writeFileSync(path.join(dir, 'fixture.swift'), source);
  const build = spawnSync('swiftc', ['-parse-as-library', path.join(dir, 'fixture.swift'), '-o', path.join(dir, 'fixture')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(path.join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PASS: event flush follows CLI persistence exactly once/);
  const shell = read('App/Sources/Tatwo2/Shell/AppShell.swift');
  const start = shell.indexOf('    func applicationShouldTerminate(_ sender: NSApplication)');
  const handler = shell.slice(start, shell.indexOf('    private func showDefaultSurfaceForUserOpen()', start));
  assert.match(handler, /TatwoInterruptGate.decision\(kind: \.appTerminate/);
  assert.match(handler, /terminationCoordinator.request/);
  assert.doesNotMatch(handler, /IslandNotice|confirmBlocking/);
});
