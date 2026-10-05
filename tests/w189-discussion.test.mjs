import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('F11 baseline and repaired production discussion creation produce different liveness', () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const sourcePath = 'App/Sources/Tatwo2/Facade/ChatLiveEngine.swift';
  const historical = spawnSync('git', ['show', `885f00dd:${sourcePath}`], { cwd: root, encoding: 'utf8' });
  assert.equal(historical.status, 0, historical.stderr);
  const current = readFileSync(join(root, sourcePath), 'utf8');
  const extract = source => {
    const start = source.indexOf('    func createDiscussion(', source.indexOf('final class ChatLiveEngine'));
    return source.slice(start, source.indexOf('    @discardableResult\n    func compressDiscussion(', start));
  };
  const baseline = extract(historical.stdout).replace('func createDiscussion(', 'func baselineDiscussion(');
  const repaired = extract(current);
  assert.ok(baseline.includes('return discussion.id') && repaired.includes('return discussion.id'));
  const plumbing = readFileSync(join(root, 'App/Sources/Tatwo2/Facade/Tatwo2PlumbingStubs.swift'), 'utf8');
  const liveness = plumbing.slice(plumbing.indexOf('enum ThreadLiveness:'), plumbing.indexOf('struct TatwoNativeChatThread:'));
  const scratch = testScratch('w189-discussion-');
  const fixture = join(scratch, 'main.swift');
  writeFileSync(fixture, `import Foundation
${liveness}
struct LiveThreadRecord {
 var id = UUID(); let projectID: UUID; var title: String; var engine: String; var model: String?; var enabledMCP: [String]
 var isArchived = false; var parentThreadID: UUID?; var subStatus: String?; var roomReadOnly: Bool?; var cwdOverride: String?
 var requestedModel: String?; var requestedEffort: String?; var requestedSpeedTier: String?; var memoryStrength: String?
}
struct Document { var threads: [LiveThreadRecord]; var selectedThreadID: UUID? }
final class Probe {
 let parent = LiveThreadRecord(projectID: UUID(), title: "fixture", engine: "fixture", model: nil, enabledMCP: [])
 lazy var doc = Document(threads: [parent]); var messages: [UUID: [String]] = [:]
 func persist() {}
 ${baseline}
 ${repaired}
}
let old = Probe(), new = Probe()
let oldID = old.baselineDiscussion(parentThreadID: old.parent.id)!
let newID = new.createDiscussion(parentThreadID: new.parent.id)!
let before = ThreadLiveness.from(status: old.doc.threads.first { $0.id == oldID }!.subStatus, lastOutputAt: nil)
let after = ThreadLiveness.from(status: new.doc.threads.first { $0.id == newID }!.subStatus, lastOutputAt: nil)
precondition(before == nil && after == .idle)
print("F11 BASELINE fresh-child-listed FAIL liveness=nil")
print("F11 REPAIRED fresh-child-listed PASS liveness=idle")
print("F11 SUMMARY baseline_failures=1 repaired_failures=0")
`);
  const build = spawnSync('swiftc', [fixture, '-o', join(scratch, 'probe')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(scratch, 'probe'), [], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  console.log(run.stdout.trim());
  assert.match(run.stdout, /F11 SUMMARY baseline_failures=1 repaired_failures=0/);
});
