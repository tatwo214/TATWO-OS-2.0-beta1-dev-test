import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('actual create_project validation rejects controls and newlines before trimming', () => {
  const source = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsService.swift', import.meta.url), 'utf8');
  const method = source.slice(source.indexOf('func createProject('), source.indexOf('func readSession('));
  const name = method.slice(method.indexOf('        let name ='), method.indexOf('        projectCreationLock.lock()'));
  const folder = method.slice(method.indexOf('        let relative ='), method.indexOf('\n', method.indexOf('invalid_project_folder:')) + 1);
  assert.ok(name.includes('guard') && folder.includes('guard'), 'compile the actual validation statements');
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'w225a3-controls-'));
  try {
    const swift = path.join(base, 'main.swift'), binary = path.join(base, 'validation');
    fs.writeFileSync(swift, String.raw`
import Foundation
enum HandsToolError: Error { case invalid(String) }
enum TatwoMemoryStore { static func containsSecret(_ value: String) -> Bool { false } }
enum HandsSecretFiles { static func isSecret(path: String) -> Bool { false } }
func validateName(_ raw: String) throws {
${name}
}
func validateFolder(_ folder: String?) throws {
    let unique = "Fixture"
${folder}
}
var failures = 0
let bad = ["bad\nname", "bad\rname", "bad\tname", "bad\u{001B}name", "bad\u{007F}name",
           "bad\u{0085}name", "bad\u{2028}name", "bad\u{2029}name", "\nleading", "trailing\n"]
for value in bad {
    for (label, validate) in [("name", validateName), ("folder", { try validateFolder($0) })] {
        do { try validate(value); print("FAIL accepted \(label): \(value.debugDescription)"); failures += 1 } catch { }
    }
}
for value in ["Normal name", "研究專案", " padded "] {
    do { try validateName(value) } catch { print("FAIL valid name"); failures += 1 }
}
for value in ["normal folder", "research/topic", "研究/資料"] {
    do { try validateFolder(value) } catch { print("FAIL valid folder"); failures += 1 }
}
exit(failures == 0 ? 0 : 1)
`);
    const compiled = spawnSync('swiftc', [swift, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
    assert.equal(compiled.status, 0, compiled.stderr);
    const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});
