import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('restoration OCR joins line wraps while preserving spaces and tabs', () => {
  const source = fs.readFileSync('App/Sources/Tatwo2/DM/DeviceFlowAcceptance.swift', 'utf8');
  const statement = source.split('\n').find(line => line.includes('let unwrappedText = text.'));
  assert.ok(statement);
  const root = testScratch('w221b-ocr-');
  fs.writeFileSync(path.join(root, 'main.swift'), `import Foundation
for (text, expected) in [("不\\n寫檔", true), ("不\\r\\n寫檔", true), ("不 寫檔", false), ("不\\t寫檔", false), ("不　寫檔", false)] {
    ${statement}
    precondition(unwrappedText.contains("不寫檔") == expected, "OCR must preserve non-newline whitespace")
}
print("W221b OCR PASS")
`);
  const binary = path.join(root, 'probe');
  execFileSync('/usr/bin/swiftc', [path.join(root, 'main.swift'), '-o', binary]);
  assert.match(execFileSync(binary, { encoding: 'utf8' }), /OCR PASS/);
});
