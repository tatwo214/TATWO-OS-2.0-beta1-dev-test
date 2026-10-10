import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/TapProjectMap.swift', import.meta.url), 'utf8');
const section = source.slice(source.indexOf('    private var lifecycle:'), source.indexOf('    private enum ResolutionError:'));
test('W222c-4 production lifecycle isolates failed writes, clears tasks and permits retry', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w222c-lifecycle-'));
  try {
    writeFileSync(join(dir, 'check.swift'), `import Foundation
struct Map { var archived: Bool? }
enum TapError: LocalizedError { case remote(String); var errorDescription: String? { if case .remote(let s) = self { return s }; return nil } }
enum HandsRedactor { struct Context { var paths: [String]; var hostName: String?; var userName: String? }; static func redact(_ s: String, context: Context) -> String { s } }
actor Storage {
 var failed = true; var maps: [String: Map] = [:]
 func update(at folder: URL, change: @Sendable (inout Map) -> Void) throws {
  if folder.path == "/bad" && failed { throw TapError.remote("fixture permission denied\\nsecond line") }
  var map = maps[folder.path] ?? Map(); change(&map); maps[folder.path] = map
 }
 func recover() { failed = false }
 func archived(_ folder: URL) -> Bool { maps[folder.path]?.archived == true }
}
@MainActor final class Mapper {
 let storage = Storage()
${section}
 var pending: Bool { lifecycle != nil }
 var reasons: [String: String] { Mirror(reflecting: self).children.first { $0.label == "lifecycleErrors" }?.value as? [String: String] ?? [:] }
}
@main enum Check {
 @MainActor static func main() async throws {
  let mapper = Mapper(), bad = URL(fileURLWithPath: "/bad"), good = URL(fileURLWithPath: "/good")
  mapper.setArchived([bad, good], archived: true)
  var error: Error?
  do { try await mapper.waitForLifecycle() } catch let failure { error = failure }
  precondition(error == nil, "failed archive poisons waitForLifecycle")
  let archivedGood = await mapper.storage.archived(good)
  precondition(archivedGood, "failed folder prevents later folders from being written")
  precondition(!mapper.pending && mapper.reasons[bad.path]?.contains("permission denied") == true && mapper.reasons[bad.path]?.contains("\\n") == false, "completed task or one-line reason missing")
  try await mapper.waitForLifecycle()
  await mapper.storage.recover()
  mapper.setArchived([bad], archived: true); try await mapper.waitForLifecycle()
  let archivedBad = await mapper.storage.archived(bad)
  precondition(archivedBad && mapper.reasons[bad.path] == nil && !mapper.pending, "next archive cannot retry")
  mapper.setArchived([bad], archived: false); mapper.setArchived([good], archived: false)
  try await mapper.waitForLifecycle()
  let restoredBad = await mapper.storage.archived(bad), restoredGood = await mapper.storage.archived(good)
  precondition(!restoredBad && !restoredGood && !mapper.pending, "queued restore lost or task retained")
  print("W222c-4 PASS failure isolation/clear/retry/queued restore")
 }
}
`);
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', join(dir, 'check.swift'), '-o', join(dir, 'check')], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(join(dir, 'check'), [], { encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, `${run.stdout}\n${run.stderr.slice(0, 1200)}`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
