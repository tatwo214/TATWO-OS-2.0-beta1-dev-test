import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';

test('production cancellation freezes its group before kill; TERM control can still execute a shell trap',
  { skip: process.platform !== 'darwin', timeout: 30000 }, async () => {
    const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsSandbox.swift', import.meta.url), 'utf8');
    const begin = source.indexOf('    static func terminate(where');
    const end = source.indexOf('    static func isRunning(where', begin);
    assert.ok(begin >= 0 && end > begin);
    const terminate = source.slice(begin, end);
    assert.ok(terminate.indexOf('SIGSTOP') < terminate.indexOf('SIGKILL'));
    assert.doesNotMatch(terminate, /kill\(-group, SIGTERM\)|usleep/);
    const dir = mkdtempSync(join(tmpdir(), 'tatwo-cancel-freeze-'));
    const swift = `
import Darwin
import Foundation
enum HandsPath { static func realpath(_ path: String) -> String? { path } }
enum Harness {
    struct RunTag { let selected: Bool }
    static let liveLock = NSLock()
    static var liveGroups: [Int32: RunTag] = [:]
    static var cancelledGroups: Set<Int32> = []
    static func sweep(mark: String, control: String) -> Int? { nil }
${terminate}
}
let pid = Int32(CommandLine.arguments[1])!
precondition(pid > 1 && pid != getpgrp())
Harness.liveGroups[pid] = .init(selected: true)
precondition(Harness.terminate(where: { $0.selected }, workspaces: [], marksDirectory: nil) == 0)
precondition(Harness.cancelledGroups.contains(pid))
`;
    const path = join(dir, 'main.swift'), binary = join(dir, 'cancel');
    writeFileSync(path, swift);
    const build = spawnSync('swiftc', [path, '-o', binary], { encoding: 'utf8', timeout: 15000 });
    assert.equal(build.status, 0, build.stderr);

    async function exercise(control) {
      // Only this test's own detached process group is signalled. A real TERM
      // handler is a positive control: successful cancellation must never run it.
      const child = spawn('/bin/zsh', ['-f', '-c',
        'trap "print AFTER_CANCEL" TERM; print READY; while true; do /bin/sleep 10; done'],
        { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '', error = '';
      child.stdout.on('data', b => { output += b; });
      child.stderr.on('data', b => { error += b; });
      const closed = once(child, 'close');
      const waitFor = async predicate => {
        const until = Date.now() + 4000;
        while (!predicate() && Date.now() < until) await new Promise(r => setTimeout(r, 10));
        assert.ok(predicate(), `${output}\n${error}`);
      };
      try {
        await waitFor(() => output.includes('READY'));
        // The shell is already in its wait, matching the cancellation regression.
        await new Promise(r => setTimeout(r, 100));
        if (control) {
          process.kill(-child.pid, 'SIGTERM');
          await waitFor(() => output.includes('AFTER_CANCEL'));
        } else {
          const cancel = spawnSync(binary, [String(child.pid)], { encoding: 'utf8', timeout: 5000 });
          assert.equal(cancel.status, 0, cancel.stderr);
          const [code, signal] = await closed;
          assert.equal(code, null);
          assert.equal(signal, 'SIGKILL');
          assert.doesNotMatch(output, /AFTER_CANCEL/);
        }
      } finally {
        try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
        await closed;
      }
    }
    await exercise(true);
    for (let round = 0; round < 5; round++) await exercise(false);
  });
