import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/ChatLiveEngine.swift', import.meta.url), 'utf8');
const method = source.slice(source.indexOf('    func restoreThreadProjects('), source.indexOf('    /// 存檔成功才換上新文件', source.indexOf('    func restoreThreadProjects(')));
test('W222c-3 classification undo leaves the original project folder active', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w222c-folder-'));
  try {
    writeFileSync(join(dir, 'check.swift'), `import Foundation
struct LiveProjectRecord { var id: UUID; var workdir: String }
struct Thread { var id: UUID; var parentThreadID: UUID?; var projectID: UUID }
struct ProjectMoveEntry { var threadID: UUID; var from: UUID?; var to: UUID }
struct Document { var projects: [LiveProjectRecord]; var threads: [Thread]; var generalProjectID: UUID?; var assistantProjectID: UUID? }
final class Mapper { var archived = Set<String>(); func setArchived(_ folders: [URL], archived: Bool) { for f in folders { if archived { self.archived.insert(f.standardizedFileURL.path) } else { self.archived.remove(f.standardizedFileURL.path) } } }; func destination(_ folder: URL) -> String { archived.contains(folder.standardizedFileURL.path) ? "inbox" : "g-p-original" } }
final class ChatLiveEngine {
 var doc: Document; let tapMapper = Mapper()
 init(_ doc: Document) { self.doc = doc }
 func commitMoved(_ next: Document) throws { doc = next }
${method}
}
let original = UUID(), classified = UUID(), thread = UUID(), folder = URL(fileURLWithPath: "/fixture")
// Classification creates a distinct project record using the source folder.
let engine = ChatLiveEngine(Document(projects: [.init(id: original, workdir: folder.path), .init(id: classified, workdir: "/fixture/./")], threads: [.init(id: thread, projectID: classified)], generalProjectID: nil, assistantProjectID: nil))
let undone = try engine.restoreThreadProjects([.init(threadID: thread, from: original, to: classified)], archivingEmpty: [classified])
precondition(undone.archived.map(\\.id) == [classified] && engine.doc.threads.first?.projectID == original)
precondition(engine.tapMapper.destination(folder) == "g-p-original", "undo archived the original shared folder")
let solo = UUID(), separate = URL(fileURLWithPath: "/separate")
engine.doc.projects.append(.init(id: solo, workdir: separate.path))
_ = try engine.restoreThreadProjects([], archivingEmpty: [solo])
precondition(engine.tapMapper.destination(separate) == "inbox", "sole project must still be archived")
print("W222c-3 PASS shared folder stays active; sole folder archives")
`);
    const compile = spawnSync('/usr/bin/swiftc', [join(dir, 'check.swift'), '-o', join(dir, 'check')], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(join(dir, 'check'), [], { encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, `${run.stdout}\n${run.stderr.slice(0, 1200)}`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
