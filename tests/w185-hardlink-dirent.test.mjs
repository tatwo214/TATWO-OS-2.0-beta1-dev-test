import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('hardlink scanner bounds variable dirents and retains fail-closed isolation', { skip: process.platform !== 'darwin' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-dirent-'));
  const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsHardLinks.swift', import.meta.url), 'utf8').split('extension HandsService')[0];
  writeFileSync(join(dir, 'main.swift'), source + `
enum HandsToolError: Error { case invalid(String) }
func check(_ value: Bool) { precondition(value) }
func refuses(_ body: () throws -> Void) {
    do { try body(); fatalError("expected refusal") } catch {}
}
let page = Int(getpagesize())
let raw = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
precondition(raw != MAP_FAILED)
precondition(mprotect(raw.advanced(by: page), page, PROT_NONE) == 0)
let offset = MemoryLayout<dirent>.offset(of: \\.d_name)!
let entry = raw.advanced(by: page - 32).assumingMemoryBound(to: dirent.self)
entry.pointee.d_reclen = 32
entry.pointee.d_namlen = 1
let bytes = UnsafeMutableRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
bytes[0] = 120; bytes[1] = 0
check(try HandsHardLinks.entryName(UnsafePointer(entry)) == [120])
entry.pointee.d_namlen = 1024
refuses { _ = try HandsHardLinks.entryName(UnsafePointer(entry)) }
entry.pointee.d_namlen = 1; bytes[1] = 1
refuses { _ = try HandsHardLinks.entryName(UnsafePointer(entry)) }
bytes[1] = 0; bytes[0] = 47
refuses { _ = try HandsHardLinks.entryName(UnsafePointer(entry)) }
bytes[0] = 0
refuses { _ = try HandsHardLinks.entryName(UnsafePointer(entry)) }
munmap(raw, page * 2)
let fm = FileManager.default
let root = CommandLine.arguments[1] + "/fixture"
try fm.createDirectory(atPath: root + "/inside/sub", withIntermediateDirectories: true)
try Data("safe".utf8).write(to: URL(fileURLWithPath: root + "/inside/one"))
// APFS Unicode filenames may occupy more UTF-8 bytes than NAME_MAX.
try Data("unicode".utf8).write(to: URL(fileURLWithPath: root + "/inside/" + String(repeating: "界", count: 100)))
check(try HandsHardLinks.outsideLink(under: root + "/inside") == nil)
try fm.linkItem(atPath: root + "/inside/one", toPath: root + "/inside/sub/two")
check(try HandsHardLinks.outsideLink(under: root + "/inside") == nil)
try fm.linkItem(atPath: root + "/inside/one", toPath: root + "/outside")
check(try HandsHardLinks.outsideLink(under: root + "/inside") != nil)
check(try HandsHardLinks.outsideLink(under: root) == nil)
try fm.createSymbolicLink(atPath: root + "/inside/shortcut", withDestinationPath: root)
check(try HandsHardLinks.outsideLink(under: root) == nil)
refuses { _ = try HandsHardLinks.outsideLink(under: root, limit: 1) }
refuses { _ = try HandsHardLinks.outsideLink(under: root, maxDepth: 0) }
refuses { _ = try HandsHardLinks.outsideLink(under: root + "/missing") }
refuses { _ = try HandsHardLinks.outsideLink(under: root + "/inside/shortcut") }
print("PASS guard-page malformed-record internal-link external-link symlink depth limit unreadable")
`);
  const build = spawnSync('swiftc', ['-Onone', join(dir, 'main.swift'), '-o', join(dir, 'scanner')], { encoding: 'utf8', timeout: 120000 });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(dir, 'scanner'), [dir], { encoding: 'utf8', timeout: 60000 });
  assert.equal(run.status, 0, `${run.signal}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /PASS guard-page/);
});

test('quarantine and both submission scanners use bounded names, never copy a dirent tuple', () => {
  for (const [file, count] of [['HandsQuarantine.swift', 1], ['HandsRooms.swift', 2]]) {
    const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/' + file, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /withUnsafeBytes\(of:\s*entry\.pointee\.d_name/);
    assert.equal((source.match(/HandsHardLinks\.entryName\(UnsafePointer\(entry\)\)/g) ?? []).length, count);
  }
});

test('real quarantine scan survives large directory buffers and preserves isolation decisions', { skip: process.platform !== 'darwin' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-quarantine-dirent-'));
  const read = name => readFileSync(new URL('../App/Sources/Tatwo2/Facade/' + name, import.meta.url), 'utf8');
  const hardlinks = read('HandsHardLinks.swift').split('extension HandsService')[0];
  const floors = read('HandsFloors.swift');
  // Use the actual production name policy, not a permissive secret-name stub.
  const policy = floors.slice(floors.indexOf('enum HandsSecretFiles {'), floors.indexOf('    /// 相對路徑')) + '\n}\n';
  assert.ok(policy.includes('static func isSecret(name'));
  writeFileSync(join(dir, 'main.swift'), hardlinks + '\n' + policy + '\n' + read('HandsQuarantine.swift') + `
enum HandsToolError: Error { case invalid(String) }
let fm = FileManager.default
let root = CommandLine.arguments[1] + "/fixture"
try fm.createDirectory(atPath: root + "/nested/.git", withIntermediateDirectories: true)
try fm.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
for i in 0..<5000 {
    try Data().write(to: URL(fileURLWithPath: root + "/file-\\(i)-" + String(repeating: "x", count: i % 160)))
}
try Data().write(to: URL(fileURLWithPath: root + "/" + String(repeating: "界", count: 100)))
try Data("fixture only".utf8).write(to: URL(fileURLWithPath: root + "/nested/.env-test"))
try fm.createDirectory(atPath: root + "-outside", withIntermediateDirectories: true)
try Data().write(to: URL(fileURLWithPath: root + "-outside/.env-not-followed"))
try fm.createSymbolicLink(atPath: root + "/shortcut", withDestinationPath: root + "-outside")
func scan(_ nested: Bool, limit: Int = 500_000) throws -> Set<String> {
    let fd = try HandsQuarantine.openDirectory(root)
    defer { close(fd) }
    return Set(try HandsQuarantine.scan(fd, nestedGit: nested, limit: limit))
}
let nestedResult = try scan(true)
precondition(nestedResult == Set(["nested/.git", "nested/.env-test"]))
let namesResult = try scan(false)
precondition(namesResult == Set(["nested/.env-test"]))
do { _ = try scan(true, limit: 1); fatalError("limit must refuse") } catch {}
precondition(fm.fileExists(atPath: root + "/nested/.env-test")) // scan only, never move
print("QUARANTINE DIRENT PASS large-directory unicode nested-git secret-policy symlink limit")
`);
  const path = join(dir, 'main.swift');
  const build = spawnSync('swiftc', ['-Onone', path, '-o', join(dir, 'scanner')], { encoding: 'utf8', timeout: 120000 });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(dir, 'scanner'), [dir], { encoding: 'utf8', timeout: 60000 });
  assert.equal(run.status, 0, `${run.signal}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /QUARANTINE DIRENT PASS/);
});
