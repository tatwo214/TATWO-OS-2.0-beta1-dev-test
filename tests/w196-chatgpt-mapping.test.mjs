import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

test('W196 temporary Node locator executes isolation, regular-file and sandbox guards', { timeout: 120_000 }, () => {
  const root = fs.realpathSync(fs.mkdtempSync('/tmp/w196-node-'));
  try {
    const candidate = root + '/node';
    fs.writeFileSync(candidate, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const source = fs.readFileSync('App/Sources/Tatwo2/Facade/HandsUIAcceptance.swift', 'utf8');
    const locator = source.slice(source.indexOf('    static func findNode()'), source.indexOf('    /// W183 R5b', source.indexOf('    static func findNode()')));
    const fixture = root + '/Checks.swift';
    fs.writeFileSync(fixture, `import Foundation
import Darwin
enum HandsGatewayLaunch {
    static func accountHome() -> String { ProcessInfo.processInfo.environment["HOME"]! }
    static func realPath(_ value: String) -> String? {
        guard let pointer = realpath(value, nil) else { return nil }
        defer { free(pointer) }; return String(cString: pointer)
    }
}
struct EnginePaths { var runtimeBinDirectory: URL { URL(fileURLWithPath: HandsGatewayLaunch.accountHome()).appendingPathComponent("runtime") } }
enum Locator { ${locator} }
@main struct Checks {
    static func main() { print(Locator.findNode()?.path ?? "none") }
}
`);
    const binary = root + '/checks';
    const build = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2', 'App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift', fixture, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
    assert.equal(build.status, 0, build.stderr);
    const env = { ...process.env, HOME: root + '/home', CFFIXED_USER_HOME: root + '/home', TATWO_STAGING_ROOT: root,
      TATWO_STAGING_SCRATCH_HOME: root + '/home', TATWO2_LIVE_ROOT: root + '/live', TATWO2_ENGINES_ROOT: root + '/engines',
      CODEX_HOME: root + '/engines/codex', TATWO2_CODEX_SOURCE_HOME: root + '/engines/codex',
      CLAUDE_CONFIG_DIR: root + '/engines/claude', CLAUDE_SECURESTORAGE_CONFIG_DIR: root + '/engines/claude',
      TATWO2_OS_ROOT: root + '/os', TATWO2_DOCS_ROOT: root + '/docs', TATWO2_OS_UPSTREAM_PATH: root + '/os/os.md',
      TATWO2_SKILLET_PATH: root + '/os/skillet.md', TATWO2_OS_SOCKET: root + '/o.sock', TATWO2_BROWSER_SOCKET: root + '/b.sock',
      TATWO2_SELFTEST: 'w185tools', TATWO2_SELFTEST_NODE: candidate };
    fs.mkdirSync(env.HOME);
    const locate = (overrides = {}) => {
      const result = spawnSync(binary, [], { env: { ...env, ...overrides }, encoding: 'utf8', timeout: 10_000 });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim();
    };
    assert.equal(locate(), candidate);
    assert.equal(locate({ TATWO2_SELFTEST: 'w183ui' }), candidate);
    for (const overrides of [{ TATWO2_SELFTEST: 'w185tap' }, { TATWO_STAGING_ROOT: '' }, { TATWO2_LIVE_ROOT: '/outside' }, { CFFIXED_USER_HOME: root + '/other' }]) assert.notEqual(locate(overrides), candidate);
    fs.chmodSync(candidate, 0o600); assert.notEqual(locate(), candidate); fs.chmodSync(candidate, 0o700);
    fs.linkSync(candidate, root + '/hardlink'); assert.notEqual(locate(), candidate); fs.unlinkSync(root + '/hardlink');
    assert.notEqual(locate({ TATWO2_SELFTEST_NODE: root }), root);
    assert.equal(spawnSync('mkfifo', [root + '/fifo']).status, 0);
    fs.chmodSync(root + '/fifo', 0o700); assert.notEqual(locate({ TATWO2_SELFTEST_NODE: root + '/fifo' }), root + '/fifo');
    fs.copyFileSync(candidate, env.HOME + '/node'); fs.chmodSync(env.HOME + '/node', 0o700);
    fs.symlinkSync(env.HOME + '/node', root + '/escape');
    for (const file of [env.HOME + '/node', root + '/escape']) assert.notEqual(locate({ TATWO2_SELFTEST_NODE: file }), env.HOME + '/node');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
