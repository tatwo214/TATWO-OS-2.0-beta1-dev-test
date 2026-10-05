import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
test('M3/Sol M1: bundled Codex supports the default generation and verifies the downloaded native hash', () => {
  const script = read('scripts/bundle-engines.sh');
  assert.match(script, /CODEX_VERSION="0\.160\.0"/);
  assert.match(script, /CODEX_SHA256="[0-9a-f]{64}"/);
  assert.match(script, /shasum -a 256 "\$CODEX_NATIVE"/);
  assert.match(script, /actual.*CODEX_SHA256/);
});
test('M3: local runtime selection verifies Developer ID against bundled Team ID and compares semantic versions', () => {
  const file = new URL('../App/Sources/Tatwo2/Facade/EngineRuntimeSelection.swift', import.meta.url);
  assert.ok(existsSync(file), 'missing engine version selector');
  const source = readFileSync(file, 'utf8');
  // W194-S1: verification is Security.framework's result and certificate requirement,
  // including the bundled Team, rather than printable codesign metadata.
  const signing = source.slice(source.indexOf('private static func signingIdentity('), source.indexOf('private static func inspect('));
  assert.match(source, /import Security/);
  assert.match(signing, /guard SecStaticCodeCreateWithPath\(path as CFURL, \[\], &code\) == errSecSuccess, let code else \{ return \(false, false, nil\) \}/);
  assert.match(signing, /let flags = SecCSFlags\(rawValue: kSecCSStrictValidate \| kSecCSCheckAllArchitectures\)/);
  assert.match(signing, /let verified = SecStaticCodeCheckValidity\(code, flags, nil\) == errSecSuccess/);
  assert.match(signing, /guard verified, SecCodeCopySigningInformation\(code, SecCSFlags\(rawValue: kSecCSSigningInformation\), &information\) == errSecSuccess,/);
  assert.match(signing, /\[kSecCodeInfoTeamIdentifier\] as\? String,[\s\S]*?\^\[A-Z0-9\]\{10\}\$/);
  assert.match(signing, /let expected = expectedTeam \?\? team\s*guard expected == team else \{ return \(verified, false, team\) \}/);
  assert.match(signing, /anchor apple generic and certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.6\] exists/);
  assert.match(signing, /and certificate leaf\[field\.1\.2\.840\.113635\.100\.6\.1\.13\] exists and certificate leaf\[subject\.OU\] = \\\"\\\(expected\)\\\"/);
  assert.match(signing, /guard SecRequirementCreateWithString\(requirementText as CFString, \[\], &requirement\) == errSecSuccess, let requirement else \{\s*return \(verified, false, team\)/);
  assert.match(signing, /return \(verified, SecStaticCodeCheckValidity\(code, flags, requirement\) == errSecSuccess, team\)/);
  assert.doesNotMatch(source, /"--verify"|TeamIdentifier=|Developer ID Application:/);
  const inspect = source.slice(source.indexOf('private static func inspect('), source.indexOf('private static func output('));
  assert.match(inspect, /let signature = signingIdentity\(path, expectedTeam: bundled\?\.teamID\)/);
  assert.match(inspect, /verified: signature\.verified,\s*developerID: signature\.developerID, teamID: signature\.teamID/);
  assert.match(inspect, /guard bundled\.map\(\{ trustFailure\(bundled: \$0, local: candidate\) == nil \}\) \?\? true else \{ return candidate \}\s*let versionText = output\(path, \["--version"\]/);
  assert.match(source, /guard bundled\.verified, bundled\.developerID, bundled\.teamID\?\.isEmpty == false/);
  assert.match(source, /guard local\.verified else/);
  assert.match(source, /local\.teamID == bundled\.teamID/);
  assert.match(source, /guard local\.developerID, local\.teamID == bundled\.teamID else/);
  assert.match(source, /guard let version = local\.version, let baseline = bundled\.version,\s*isNewer\(version, than: baseline\) else/);
  assert.match(source, /guard pieces\.count == 3 else \{ return nil \}/);
  assert.match(source, /guard let lhs = parts\(local\), let rhs = parts\(bundled\) else \{ return false \}\s*return rhs\.lexicographicallyPrecedes\(lhs\)/);
  assert.match(read('App/Sources/Tatwo2/New/EngineLoginCard.swift'), /executableChoice/);
  assert.match(read('Engines/codex-sidecar/sidecar.mjs'), /TATWO2_CODEX_BIN/);
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /pathToClaudeCodeExecutable/);
});
