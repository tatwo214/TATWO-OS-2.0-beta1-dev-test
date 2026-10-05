import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';


test('W202 normalization preserves suffix and Unicode behavior', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const root = testScratch('w202-normalization-');
  const source = path.join(root, 'Check.swift');
  const binary = path.join(root, 'check');
  fs.writeFileSync(source, String.raw`
import Foundation
@main struct Check {
 static func main() {
  let cases: [(String, String)] = [
   ("  Fable-5-20261003[1M]\n", "fable5"), ("gpt_6.1-sol", "gpt61sol"),
   (" ChatGPT-TAP:GPT-5 ", "chatgpttapgpt5"), ("É模型２🧪", "é模型２"),
   ("[1m]", ""), ("-20261003", ""), ("gpt-20261003[1m]x", "gpt202610031mx"),
   ("-202610031", "202610031"), ("\t\n", "")]
  for (input, expected) in cases { precondition(ChatProviderModelIdentity.lookupKey(input) == expected) }
  print("W202PERF normalization PASS")
 }
}
`);
  const compile = spawnSync('swiftc', ['-O', '-parse-as-library', '-swift-version', '5',
    'App/Sources/Tatwo2/Chat/ChatProviderModelIdentity.swift', source, '-o', binary], { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 20000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /normalization PASS/);
  console.log(result.stdout.trim());
});
