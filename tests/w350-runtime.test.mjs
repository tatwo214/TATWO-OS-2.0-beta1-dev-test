import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('W350 production resolve preserves cached choice and pointers on timeout or unreadable version, rolls back bad signature and team', () => {
  const root = mkdtempSync(join(process.env.TMPDIR ?? '/tmp', 'w350-runtime-'));
  const home = join(root, 'home'), live = join(root, 'live'); mkdirSync(home); mkdirSync(live);
  const read = path => readFileSync('App/Sources/Tatwo2/' + path, 'utf8');
  let source = read('Facade/EngineRuntimeSelection.swift');
  const start = source.indexOf('    static func signingIdentity('), end = source.indexOf('    private static func inspect(', start);
  // Only replace the OS signing primitive; exercise real resolver, cache, probes and pointer writes.
  source = source.slice(0, start) + `
    static func signingIdentity(_ path: URL, expectedTeam: String?) -> (verified: Bool, developerID: Bool, teamID: String?) {
      let bad = FileManager.default.fileExists(atPath: path.path + ".bad")
      let wrong = FileManager.default.fileExists(atPath: path.path + ".wrong")
      return (!bad, !bad, wrong ? "WRONGTEAM0" : "FIXTURE001")
    }
` + source.slice(end);
  const installer = read('Facade/EngineInstall.swift');
  const pointers = installer.slice(installer.indexOf('    nonisolated static func recover('), installer.indexOf('    func install('));
  const update = read('Facade/EngineAIUpdate.swift');
  const vStart = update.indexOf('    nonisolated static func version(');
  const vEnd = update.indexOf('\n    }', vStart) + 6;
  writeFileSync(join(root, 'runtime.swift'), source);
  writeFileSync(join(root, 'stubs.swift'), `import Foundation\nimport Darwin
    enum ClaudeSidecar { enum Kind: String { case codex, claude, grok } }
    enum NativeStagingIsolation { static func isEnabled(_ env: [String: String]) -> Bool { false } }
    enum EngineAIUpdate { ${update.slice(vStart, vEnd)} }
    enum EngineInstall { ${pointers} }
  `);
  writeFileSync(join(root, 'main.swift'), `import Foundation\nimport Darwin
    let home = URL(fileURLWithPath: CommandLine.arguments[1])
    func binary(_ name: String, _ version: String) throws -> URL {
      let url = home.appendingPathComponent(name)
      try Data(("#!/bin/sh\\nprintf 'codex " + version + "\\\\n'\\n").utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      return url
    }
    DispatchQueue.global().async {
      do {
        let fm = FileManager.default, base = try binary("base", "1.0.0"), current = try binary("new", "2.0.0"), prior = try binary("old", "1.5.0")
        func reset() throws { try EngineInstall.pointers([("current", current), ("previous", prior)], in: home) }
        func resolve(force: Bool = true) -> EngineRuntimeSelection.Choice {
          EngineRuntimeSelection.resolve(kind: .codex, bundled: base, userHome: home, engineHome: home, environment: ["PATH": ""], forceVerification: force)
        }
        try reset()
        let second = floor(Date().timeIntervalSince1970)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.1)], ofItemAtPath: current.path)
        assert(resolve(force: false).version == "2.0.0")
        _ = try binary("new", "2.1.0")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.2)], ofItemAtPath: current.path)
        assert(resolve(force: false).version == "2.1.0", "same-size subsecond update must invalidate cache")
        _ = try binary("new", "2.0.0")
        for fault in ["bad", "wrong"] {
          try reset()
          assert(resolve().executable == current)
          let failure = fault == "bad" ? "#!/bin/sh\\nexit 7\\n" : "#!/bin/sh\\nsleep 4\\n"
          try Data(failure.utf8).write(to: current)
          let cached = resolve()
          assert(cached.executable == current && cached.version == "2.0.0")
          let pointer = try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("current").path)
          let previous = try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("previous").path)
          assert(pointer == current.path && previous == prior.path)
          try Data().write(to: URL(fileURLWithPath: current.path + "." + fault))
          assert(resolve().executable == prior)
          assert(!fm.fileExists(atPath: home.appendingPathComponent("previous").path))
          try fm.removeItem(atPath: current.path + "." + fault)
          _ = try binary("new", "2.0.0")
        }
        print("W350 runtime PASS"); exit(0)
      } catch { print(error); exit(1) }
    }
    dispatchMain()
  `);
  const binary = join(root, 'probe');
  const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, TATWO2_LIVE_ROOT: live };
  const built = spawnSync('swiftc', [join(root, 'runtime.swift'), join(root, 'stubs.swift'), join(root, 'main.swift'), '-o', binary], { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(built.status, 0, built.stdout + built.stderr);
  const result = spawnSync(binary, [home], { env, encoding: 'utf8', timeout: 15000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W350 runtime PASS/);
});
