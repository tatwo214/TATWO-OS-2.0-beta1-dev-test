import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {testScratch} from './helpers/test-scratch.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const bridge = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge';
const plans = ['App/Sources/Tatwo2/Chat/ChatPage+Plan.swift',
  'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Plan.swift'];
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const policy = source => source.slice(source.indexOf('enum PlanDownloadPolicy {'), source.indexOf('\nprivate struct PlanWritingAnimatedText'));
const run = (cmd, args, options = {}) => {
  const result = spawnSync(cmd, args, {...options, encoding: 'utf8', timeout: 60000});
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return result.stdout;
};

test('both PLAN export entrances only operate on their own paths', () => {
  const native = read(`${bridge}/TatwoPlanExport.mm`);
  for (const source of [native, ...plans.map(p => policy(read(p)))]) {
    assert.doesNotMatch(source, /\b(?:fileExists|contentsOfDirectory|enumerator|opendir|stat|lstat|fstatat|openat|O_DIRECTORY|renameatx_np|NSItemReplacementDirectory)\b/);
    assert.doesNotMatch(source, /fileManager\.urls/);
  }
  assert.match(native, /tatwo::DownloadCandidateName\(name.UTF8String, i\)/);
  assert.match(native, /renamex_np\([^;]+RENAME_EXCL/);
  assert.match(native, /open\([^;]+O_CREAT \| O_EXCL \| O_NOFOLLOW/);
  for (const plan of plans) {
    assert.equal((read(plan).match(/PlanDownloadPolicy.download\(markdown\)/g) || []).length, 2);
    assert.match(policy(read(plan)), /error.localizedDescription/);
    assert.doesNotMatch(read(plan), /availableDestination/);
    assert.doesNotMatch(policy(read(plan)), /markdown\.write/);
  }
  assert.equal(policy(read(plans[0])), policy(read(plans[1])));
});

test('Save As writes the selected URL atomically and reports failures without TatwoPlanExport', () => {
  for (const plan of plans) {
    const source = read(plan);
    const summary = source.slice(source.indexOf('struct PlanTranscriptSummaryView: View'));
    const start = summary.indexOf('if PlanDownloadPolicy.shouldPromptForLocation()');
    const end = summary.indexOf('\n        PlanDownloadPolicy.download(markdown)', start);
    assert.ok(start >= 0 && end > start, `${plan}: Save As branch must exist`);
    const saveAs = summary.slice(start, end);
    assert.match(saveAs, /panel\.runModal\(\).*== \.OK, let url = panel\.url/);
    assert.doesNotMatch(saveAs, /TatwoPlanExport|PlanDownloadPolicy\.(?:export|download)\s*\(/);
    assert.match(saveAs, /do\s*\{\s*try markdown\.write\(to: url, atomically: true, encoding: \.utf8\)\s*\}\s*catch\s*\{\s*PlanDownloadPolicy\.report\(error\)\s*\}/);
    assert.doesNotMatch(saveAs, /try\?/);
  }
});

test('native PLAN export: collisions, UTF-8 names, short writes and failed I/O cleanup', () => {
  const scratch = testScratch('w283-native-');
  const binary = path.join(scratch, 'checks');
  run('c++', ['-std=c++17', '-framework', 'Foundation', '-framework', 'CoreFoundation',
    '-I', path.join(root, bridge), '-I', path.join(root, bridge, 'include'),
    path.join(root, 'tests/fixtures/w283-plan-export-checks.mm'), '-o', binary]);
  assert.match(run(binary, [scratch]), /PASS: W283 native/);
});

test('real Swift PLAN policy links the exporter and surfaces readable errors', () => {
  const scratch = testScratch('w283-swift-');
  const object = path.join(scratch, 'export.o');
  run('c++', ['-std=c++17', '-c', '-I', path.join(root, bridge, 'include'),
    path.join(root, bridge, 'TatwoPlanExport.mm'), '-o', object]);
  const swift = path.join(scratch, 'main.swift');
  const module = path.join(scratch, 'module.modulemap');
  fs.writeFileSync(module, `module TatwoCEFBridge { header "${path.join(root, bridge, 'include/TatwoCEFBridge.h')}" export * }`);
  fs.writeFileSync(swift, `import Foundation
import AppKit
import TatwoCEFBridge
enum TatwoModalPanelGate { static func run(_ work: () -> NSApplication.ModalResponse) { fatalError("unexpected alert") } }
${policy(read(plans[0]))}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let suite = "w283-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set(directory.path, forKey: PlanDownloadPolicy.downloadDirectoryDefaultsKey)
precondition(PlanDownloadPolicy.downloadDirectory(defaults: defaults) == directory)
for expected in ["PLAN.md", "PLAN (1).md", "PLAN (2).md"] {
    let url = try PlanDownloadPolicy.export("# PLAN\\n施工內容", in: directory)
    precondition(url.lastPathComponent == expected)
    let content = try String(contentsOf: url, encoding: .utf8)
    precondition(content == "# PLAN\\n施工內容")
}
let chosenFile = "selected.md"
for expected in ["selected.md", "selected (1).md"] {
    let url = try PlanDownloadPolicy.export("selected", in: directory, name: chosenFile)
    precondition(url.lastPathComponent == expected)
}
do {
    _ = try PlanDownloadPolicy.export("failure", in: directory.appendingPathComponent("missing", isDirectory: true))
    fatalError("missing directory must fail")
} catch {
    precondition(error.localizedDescription.contains("計畫匯出失敗"))
    precondition(error.localizedDescription.contains("ENOENT"))
}
print("PASS: W283 Swift policy")
`);
  const binary = path.join(scratch, 'checks');
  run('swiftc', ['-I', scratch,
    swift, object, '-Xlinker', '-lc++', '-o', binary]);
  const downloads = path.join(scratch, 'downloads');
  fs.mkdirSync(downloads);
  const fixtureHome = path.join(scratch, 'home');
  fs.mkdirSync(fixtureHome);
  assert.match(run(binary, [downloads], {env: {...process.env, HOME: fixtureHome, CFFIXED_USER_HOME: fixtureHome}}), /PASS: W283 Swift policy/);
});
