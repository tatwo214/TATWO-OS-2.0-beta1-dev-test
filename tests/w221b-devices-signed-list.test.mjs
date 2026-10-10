import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('DevicesCard rows use signed-list membership for staff and non-staff devices', () => {
  const source = fs.readFileSync('App/Sources/Tatwo2/New/DevicesCard.swift', 'utf8');
  const predicate = source.match(/ForEach\(model\.devices\.filter \{ row in([\s\S]*?)\}\) \{ device in/)[1];
  const root = testScratch('w221b-devices-');
  fs.writeFileSync(path.join(root, 'main.swift'), `
struct Row { let id: String }
struct Snapshot { let devices: [Row]; let isStaff: Bool }
struct Fleet { let snapshot: Snapshot }
struct Link { let device: Row }
struct Model { func primaryLinkState() -> Link? { Link(device: Row(id: "unsigned-primary")) } }
let model = Model()
for staff in [false, true] {
    let fleet = Fleet(snapshot: Snapshot(devices: [Row(id: "signed-device")], isStaff: staff))
    for id in ["signed-device", "unsigned-primary", "unknown"] {
        let row = Row(id: id)
        let visible: Bool = { ${predicate} }()
        precondition(visible == (id == "signed-device"), "unsigned row visible; staff=\\(staff) id=\\(id)")
    }
}
print("W221b signed rows PASS")
`);
  const binary = path.join(root, 'probe');
  execFileSync('/usr/bin/swiftc', [path.join(root, 'main.swift'), '-o', binary]);
  assert.match(execFileSync(binary, { encoding: 'utf8' }), /signed rows PASS/);
});
