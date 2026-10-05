import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, chmodSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');
const addedAcceptance = [
  'Chat/CommandModeAcceptance.swift', 'Facade/LoginFlowAcceptance.swift',
  'Facade/QueuedStopAcceptance.swift', 'Facade/RemoteRejectionAcceptance.swift',
  'Facade/RestartFlowAcceptance.swift', 'Facade/SendFlowAcceptance.swift',
  'Facade/StopFlowAcceptance.swift', 'Facade/UndeliveredFlowAcceptance.swift',
  'Facade/W189ModelAcceptance.swift',
];
test('A3 every .052-added acceptance declaration is inside a complete DEBUG boundary', () => {
  for (const file of addedAcceptance) {
    let depth = 0, debugDepth = 0;
    for (const line of read(file).split('\n')) {
      if (/^\s*#if\b/.test(line)) { depth++; if (line.trim() === '#if DEBUG') debugDepth = depth; }
      if (/^\s*#endif\b/.test(line)) { if (depth === debugDepth) debugDepth = 0; depth--; }
      if (/^\s*(?:@MainActor\s+)?(?:enum|class|struct|extension|func)\b/.test(line)) assert.ok(debugDepth > 0, `${file}: declaration compiled in Release: ${line.trim()}`);
    }
    assert.equal(depth, 0, file);
  }
});
test('A3 Release compilation of all .052-added acceptance files emits no acceptance symbols', {timeout:200000}, t => {
  const home = mkdtempSync(join(tmpdir(), 'w192-release-'));
  t.after(() => rmSync(home, {recursive:true, force:true}));
  const artifact = join(home, 'acceptance-release.dylib');
  const build = spawnSync('swiftc', ['-num-threads','2','-emit-library',...addedAcceptance.map(file => join(root,'App/Sources/Tatwo2',file)),'-o',artifact],
    {encoding:'utf8',timeout:160000,env:{...process.env,HOME:home}});
  assert.equal(build.status, 0, build.stderr);
  const symbols = spawnSync('/usr/bin/nm', ['-g',artifact], {encoding:'utf8'});
  assert.equal(symbols.status, 0, symbols.stderr);
  assert.doesNotMatch(symbols.stdout, /Acceptance|W189COMMANDS/);
});
test('A2 sidecar startup awaits background selection; main-thread reuse reads only the snapshot', () => {
  assert.match(read('Engine/ClaudeSidecar.swift'), /await .*selectionAsync/);
  assert.doesNotMatch(read('Engine/ClaudeSidecar.swift'), /\.selection\(for: kind, forceVerification: true\)/);
  assert.match(read('Facade/ChatLiveEngine.swift'), /cachedSelection\(for: engine\)/);
  assert.match(read('Engine/ClaudeSidecar.swift'), /startupTask\?\.cancel\(\)/);
  assert.match(read('Chat/EngineModelCatalogProbe.swift'), /onRuntimeSelection/);
});

// The certificate identity is substituted because tests must never use a signing identity.
// Actual static-code verification remains real; the W194 test additionally exercises the
// unmodified formal certificate requirement against forged Developer ID output.
test('S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe', {timeout:200000}, async t => {
  const home = mkdtempSync(join(tmpdir(), 'w192-engine-'));
  t.after(() => rmSync(home, {recursive:true, force:true}));
  const bin = join(home, '.local/bin'); mkdirSync(bin, {recursive:true});
  const bundled = join(home, 'bundled'); const local = join(bin, 'codex');
  const marker = join(home, 'executed'); const environmentDump = join(home, 'version-environment');
  function script(file, text) { writeFileSync(file, '#!/bin/sh\n' + text); chmodSync(file, 0o700); }
  script(bundled, 'sleep 0.6\nprintf "codex 0.99.0\\n"\n');
  script(local, `touch '${marker}'\n/usr/bin/env > '${environmentDump}'\nprintf 'codex 0.160.0\\n'\n`);
  for (const file of [bundled, local]) {
    const sign = spawnSync('/usr/bin/codesign', ['--force', '--sign', '-', file], {encoding:'utf8', env:{PATH:'/usr/bin:/bin', HOME:home}});
    assert.equal(sign.status, 0, sign.stderr);
  }
  const production = read('Facade/EngineRuntimeSelection.swift');
  assert.match(production, /SecStaticCodeCheckValidity/);
  const identityStart = production.indexOf('    private static func signingIdentity(');
  const identityEnd = production.indexOf('    private static func inspect(', identityStart);
  assert.ok(identityStart > 0 && identityEnd > identityStart);
  const fixtureIdentity = `    private static func signingIdentity(_ path: URL, expectedTeam: String?) -> (verified: Bool, developerID: Bool, teamID: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return (false, false, nil) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let valid = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        let mode = (try? String(contentsOf: path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mode"), encoding: .utf8)) ?? "same"
        let isBundled = path.lastPathComponent == "bundled"
        let team = !isBundled && mode == "other" ? "OTHER00001" : "FIXTURE001"
        return (valid, valid && (isBundled || mode != "adhoc") && (expectedTeam == nil || expectedTeam == team), team)
    }
`;
  const source = production.slice(0, identityStart) + fixtureIdentity + production.slice(identityEnd);
  writeFileSync(join(home, 'EngineRuntimeSelection.swift'), source);
  writeFileSync(join(home, 'stubs.swift'), `import Foundation
final class ClaudeSidecar { enum Kind: String, Sendable { case codex, claude, grok } }
enum NativeStagingIsolation { static func isEnabled(_ environment: [String:String]) -> Bool { false } }
`);
  writeFileSync(join(home, 'main.swift'), `import Foundation
let home = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
let environment = ["HOME":home.path, "PATH":"/usr/bin:/bin", "OPENAI_API_KEY":"fixture-only", "ANTHROPIC_API_KEY":"fixture-only", "CUSTOM_PROVIDER_API_KEY":"fixture-only", "GITHUB_TOKEN":"fixture-only", "DYLD_INSERT_LIBRARIES":"fixture-only"]
func selection() -> EngineRuntimeSelection.Choice {
 EngineRuntimeSelection.resolve(kind:.codex, bundled:home.appendingPathComponent("bundled"), userHome:home, engineHome:home.appendingPathComponent("engines"), environment:environment, forceVerification:true)
}
if mode == "main" {
 let start = Date(); let result = selection(); let elapsed = Date().timeIntervalSince(start)
 print("A2 main elapsed=\\(elapsed) version=\\(result.version ?? "unknown")")
 exit(elapsed < 0.15 && result.version == nil ? 0 : 1)
}
DispatchQueue.global().async {
 let result = selection()
 print("S1 selected=\\(result.source) version=\\(result.version ?? "unknown")")
 exit(mode == "same" ? (result.source == "本機" ? 0 : 1) : (result.source == "App 內附" ? 0 : 1))
}
dispatchMain()
`);
  const build = spawnSync('swiftc', ['-num-threads','2',join(home,'stubs.swift'),join(home,'EngineRuntimeSelection.swift'),join(home,'main.swift'),'-o',join(home,'probe')], {encoding:'utf8',timeout:160000});
  assert.equal(build.status, 0, build.stderr);
  for (const mode of ['adhoc', 'other', 'same', 'main']) {
    await t.test(mode === 'main' ? 'A2 slow main-thread selection returns immediately' : `S1 ${mode} candidate execution and environment`, () => {
    writeFileSync(join(home, 'mode'), mode);
    rmSync(marker, {force:true}); rmSync(environmentDump, {force:true});
    const run = spawnSync(join(home,'probe'), [home, mode], {encoding:'utf8',timeout:20000,env:{PATH:'/usr/bin:/bin',HOME:home}});
    assert.equal(run.status, 0, run.stdout + run.stderr);
    if (mode === 'adhoc' || mode === 'other') assert.ok(!existsSync(marker), `${mode}: rejected CLI executed --version`);
    if (mode === 'same') {
      assert.ok(existsSync(marker));
      const env = readFileSync(environmentDump, 'utf8');
      assert.doesNotMatch(env, /API_KEY|TOKEN|DYLD_INSERT_LIBRARIES/, env);
      assert.match(env, new RegExp(`CODEX_HOME=${home}/engines`));
    }
    console.log(run.stdout.trim());
    });
  }
});
