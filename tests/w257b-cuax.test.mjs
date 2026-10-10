import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('W257b production lease: foreign targets, renewal, ownership, failed AX calls and release duration', () => {
  const source = fs.readFileSync(new URL('../App/Sources/Tatwo2/New/ComputerUseController.swift', import.meta.url), 'utf8');
  const storage = source.slice(source.indexOf('    private static let axRequestLock'), source.indexOf('    /// 操作 TATWO OS 自己時'));
  const start = source.indexOf('        if includeTree, running.bundleIdentifier?.hasPrefix("ai.tatwo.tatwo2")');
  const block = source.slice(start, source.indexOf('        // Only real AXWindows count.', start));
  assert.ok(start > 0 && block.includes('DispatchWorkItem') && storage.includes('axRequests'));
  const dir = new URL('../.build/w257b-cuax/', import.meta.url);
  fs.mkdirSync(dir, { recursive: true });
  const fixture = `
import Foundation
import CoreFoundation
enum AXError { case success, failure }
struct Attribute { var rawValue: String }
final class Target {
    let processIdentifier: Int32
    var bundleIdentifier: String? = "ai.tatwo.tatwo2.fixture"
    var isTerminated = false
    var failSet = false
    private let lock = NSLock()
    private var demand: Bool?
    private var writes: [Bool] = []
    init(_ pid: Int32, _ demand: Bool?) { processIdentifier = pid; self.demand = demand }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return demand }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return writes.contains(false) }
    func accessibilityAttributeValue(_ attr: Attribute) -> Any? { value }
    func accessibilitySetValue(_ value: Bool, forAttribute attr: Attribute) {
        lock.lock(); defer { lock.unlock() }; demand = value; writes.append(value)
    }
}
let NSApp = Target(ProcessInfo.processInfo.processIdentifier, false)
let targets: [Int32: Target] = [101: Target(101, false), 102: Target(102, false),
    103: Target(103, true), 104: Target(104, nil), 105: Target(105, false), 106: Target(106, false)]
func AXUIElementCreateApplication(_ pid: Int32) -> Target { targets[pid]! }
func AXUIElementSetAttributeValue(_ app: Target, _ attr: CFString, _ value: CFBoolean) -> AXError {
    guard !app.failSet else { return .failure }
    app.accessibilitySetValue(CFBooleanGetValue(value), forAttribute: Attribute(rawValue: attr as String))
    return .success
}
enum ComputerUseNative {
${storage}
    static func attribute(_ app: Target, _ attr: String, deadline: TimeInterval) throws -> Any? { app.value }
    static func request(_ running: Target, includeTree: Bool = true) {
        let pid = running.processIdentifier, deadline = ProcessInfo.processInfo.systemUptime + 1
        let app = AXUIElementCreateApplication(pid)
${block}
    }
}
func read(_ pid: Int32, _ tree: Bool = true) { ComputerUseNative.request(targets[pid]!, includeTree: tree) }
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
setenv("TATWO2_CU_AX_SECONDS", "0.4", 1)
read(101, false); precondition(targets[101]!.value == false)
read(101); read(102); read(103); read(104)
targets[105]!.failSet = true; read(105)
read(106); targets[106]!.isTerminated = true
precondition(targets[101]!.value == true && targets[102]!.value == true)
wait(0.25); read(101)
wait(0.25)
#if DEBUG
precondition(targets[101]!.value == true && targets[102]!.value == false)
wait(0.25)
precondition(targets[101]!.value == false && targets[101]!.closed)
precondition(targets[103]!.value == true && !targets[103]!.closed)
precondition(targets[104]!.value == true && !targets[104]!.closed)
precondition(targets[105]!.value == false && !targets[105]!.closed)
precondition(targets[106]!.value == true && !targets[106]!.closed)
print("W257B foreign expiration, renewal, independent targets, preexisting/unknown ownership, failed setter, terminated target PASS")
#else
precondition(targets[101]!.value == true && targets[102]!.value == true)
print("W257B release ignores shortened DEBUG environment duration PASS")
#endif
`;
  const file = path.join(dir.pathname, 'main.swift');
  fs.writeFileSync(file, fixture);
  for (const flags of [['-D', 'DEBUG'], []]) {
    const binary = path.join(dir.pathname, flags.length ? 'debug-fixture' : 'release-fixture');
    const build = spawnSync('swiftc', [...flags, file, '-o', binary], { encoding: 'utf8', timeout: 60000 });
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    process.stdout.write(run.stdout);
  }
});
