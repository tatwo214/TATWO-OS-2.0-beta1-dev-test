import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, mkdirSync, chmodSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W194-A2 blocking subprocess probes use an owned thread, never a shared worker pool', () => {
  const source = read('Facade/EngineRuntimeSelection.swift');
  const asyncProbe = source.slice(source.indexOf('static func resolveAsync('), source.indexOf('static func resolve(kind:'));
  assert.doesNotMatch(asyncProbe, /Task\.detached/);
  assert.doesNotMatch(asyncProbe, /\.async\s*\{/);
  assert.match(asyncProbe, /Thread\s*\{/);
  assert.match(asyncProbe, /worker\.start\(\)/);
});
test('W194-A2 login status reads the completed runtime snapshot without spawning a version probe', () => {
  const source = read('Facade/EngineLogin.swift');
  assert.match(source, /status\.executableChoice = paths\.cachedSelection\(for: kind\)/);
  assert.doesNotMatch(source, /status\.executableChoice = paths\.selection\(for: kind\)/);
});
test('W194-S1 trust uses an Apple Developer ID and expected Team requirement, never printed metadata', () => {
  const source = read('Facade/EngineRuntimeSelection.swift');
  assert.match(source, /SecStaticCodeCheckValidity/);
  assert.match(source, /anchor apple generic/);
  assert.match(source, /1\.2\.840\.113635\.100\.6\.1\.13/);
  assert.match(source, /certificate leaf\[subject\.OU\]/);
  assert.doesNotMatch(source, /signature\.contains\("Authority=|hasPrefix\("TeamIdentifier=/);
});
test('W194-S1 a real ad-hoc signature cannot become trusted by printing Developer ID and expected Team', {timeout:180000}, t => {
  const home = mkdtempSync(join(tmpdir(), 'w194-signature-'));
  t.after(() => rmSync(home, {recursive:true, force:true}));
  const localDir = join(home, '.local/bin'); mkdirSync(localDir, {recursive:true});
  const local = join(localDir, 'codex'), bundled = join(home, 'bundled'), marker = join(home, 'executed');
  function script(path, body) {writeFileSync(path, '#!/bin/sh\n' + body); chmodSync(path, 0o700);}
  script(bundled, 'printf "codex 0.1.0\\n"\n');
  script(local, `touch '${marker}'\nprintf 'codex 0.2.0\\n'\n`);
  for (const file of [bundled, local]) {
    const result = spawnSync('/usr/bin/codesign', ['--force','--sign','-',file], {encoding:'utf8'});
    assert.equal(result.status, 0, result.stderr);
  }
  const codesign = join(home, 'codesign-fixture');
  script(codesign, `if [ "$1" = --verify ]; then exec /usr/bin/codesign "$@"; fi\nprintf 'Authority=Developer ID Application: Forged Fixture\\nTeamIdentifier=FIXTURE001\\n'\n`);
  const source = read('Facade/EngineRuntimeSelection.swift').replaceAll('"/usr/bin/codesign"', JSON.stringify(codesign));
  writeFileSync(join(home,'runtime.swift'), source);
  writeFileSync(join(home,'stubs.swift'), `import Foundation
final class ClaudeSidecar {enum Kind: String, Sendable {case codex, claude, grok}}
enum NativeStagingIsolation {static func isEnabled(_ environment:[String:String]) -> Bool {false}}
`);
  writeFileSync(join(home,'main.swift'), `import Foundation
let home = URL(fileURLWithPath: CommandLine.arguments[1])
DispatchQueue.global().async {
 let choice = EngineRuntimeSelection.resolve(kind:.codex, bundled:home.appendingPathComponent("bundled"), userHome:home, engineHome:home, environment:["PATH":"/usr/bin:/bin"], forceVerification:true)
 print("W194-S1 source=\\(choice.source)")
 exit(choice.source == "App 內附" ? 0 : 1)
}
dispatchMain()
`);
  const binary = join(home,'probe');
  const build = spawnSync('swiftc',['-num-threads','2',join(home,'stubs.swift'),join(home,'runtime.swift'),join(home,'main.swift'),'-o',binary],{encoding:'utf8',timeout:150000});
  assert.equal(build.status, 0, build.stderr);
  const result = spawnSync(binary,[home],{encoding:'utf8',timeout:15000});
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(existsSync(marker), false, 'the falsely claimed Developer ID must execute zero times');
});
