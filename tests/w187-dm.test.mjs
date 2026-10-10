import { runIsolated } from './helpers/w187-runtime.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';
import path from 'node:path';

const read = file => readFileSync(`App/Sources/Tatwo2/${file}`, 'utf8');

test('W187c device entry lives in assistant DM and remains independent of canSend/model authentication', () => {
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /if target == \.assistant \{ DeviceFlowChip\(session: \.shared\) \}/);
  assert.match(view, /DeviceFlowCard\(session: fleet\)/);
  const chip = read('New/DeviceFlowCards.swift').split('struct DeviceFlowChip')[1].split('struct DeviceFlowCard')[0];
  assert.doesNotMatch(chip, /canSend|isLoggedIn|sendToAssistant/);
  assert.match(read('SelfTest.swift'), /"w187dm"/);
  assert.match(read('SelfTest.swift'), /"w185tools"/);
  assert.match(read('SelfTest.swift'), /"w187tools"/);
  assert.equal((read('SelfTest.swift').match(/TATWO2_SELFTEST"\] == "w185tools"/g) ?? []).length, 1, 'Hands self-test cannot be shadowed by fleet tools');
});

test('W187c tool boundary has no confirmation or enrollment-secret parameters', () => {
  const source = read('Assistant/AssistantFleetTools.swift');
  assert.match(source, /\["fleet_overview", "fleet_open_card", "fleet_propose"\]/);
  assert.doesNotMatch(source, /\.confirm\(|\.beginTransfer\(|startPairingWindow\(/);
  assert.match(source, /"confirmed": false/);
  assert.match(source, /thread == assistantThread/);
  assert.match(source, /CFGetTypeID\(flag\) == CFBooleanGetTypeID/);
  assert.match(source, /Set\(parameters.keys\) == \["baseVersion", "changes"\]/);
  assert.match(source, /case "set_edge"/);
  const projection = source.split('static func overview')[1].split('private static func reference')[0];
  assert.doesNotMatch(projection, /\.name|\.endpoints|\.clientPublicKey|\.hostPublicKey|\.code|\.address|Fingerprint/);
});

test('W187c physical card confirmation, same store token, and local-only transfer path', {timeout:240_000}, () => {
  const session = read('DM/DeviceFlowSession.swift');
  const cards = read('New/DeviceFlowCards.swift');
  assert.match(session, /store\.confirm\(token, userConfirmed: true\)/);
  assert.match(cards, /eventSourceUnixProcessID\) == 0/);
  assert.match(cards, /eventSourceStateID/);
  assert.match(cards, /sheet\(isPresented: \$confirmingTransfer/);
  assert.match(cards, /action\("確認移交/);
  assert.match(session, /dispatch\.beginTransfer\(to: target, signingName: name\)/);
  assert.match(session, /graph\.kind\(of: \$0\.id\) == \.owner/);
  const checkpoints = read('New/DeviceFlowTransferPanel.swift');
  assert.match(checkpoints, /if let primary = peers\.first/);
  const { output } = runIsolated('w187fleet', {TATWO2_W187_R8:'ui-primary'});
  assert.match(output, /R10-LIGHT-01-no-duplicate-start-controls/);
  assert.match(checkpoints, /guard authority\.consume\(binding: binding\)/);
  assert.match(checkpoints, /DeviceFlowPhysicalButton/);
  assert.match(cards, /WindowCaptureShield\.shared\.hold/);
  assert.match(cards, /DMSecretCodeView\.isSuppressed/);
});

test('W187c sandbox card offers only another TATWO computer; managed consent stays on joining computer', () => {
  const cards = read('New/DeviceFlowCards.swift');
  const sandbox = cards.split('private var sandbox:')[1].split('private var permissions:')[0];
  assert.ok(sandbox);
  assert.doesNotMatch(sandbox, /Linux|Dots|小幫手/);
  assert.match(sandbox, /另一台裝了 TATWO OS 的電腦當沙盒/);
  const join = cards.split('private var join:')[1].split('private var progress:')[0];
  assert.match(join, /只有你在這台按「同意被管理」才會開放控制/);
  assert.match(join, /action\("讀取管理權限"/);
  assert.match(cards, /action\(session.awaitingInitialConsent/);
  assert.match(read('DM/DeviceFlowSession.swift'), /consentToManagement: kind != \.owner/);
  assert.match(read('Facade/DevicePairingDiscovery.swift'), /makeNonce\(\)/);
  assert.doesNotMatch(read('Facade/DevicePairingDiscovery.swift'), /"code":/);
});

test('W187c2 bridge registers and dispatches only the three assistant fleet tools', () => {
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.match(bridge, /if AssistantFleetTools.methods.contains\(method\) \{ return AssistantFleetTools.allows\(caller\) \}/);
  assert.match(bridge, /case "fleet_overview", "fleet_open_card", "fleet_propose":\s+guard let bound = context.boundThread/);
  assert.match(bridge, /AssistantFleetTools.perform\(method, params: params, caller: \.engine\(bound\),\s+assistantThread: self\?\.model\?\.assistantThreadID/);
  for (const name of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    const block = bridge.split(`static let ${name}:`)[1].split(']')[0];
    assert.doesNotMatch(block, /fleet_overview|fleet_open_card|fleet_propose/);
  }
  assert.match(read('DM/DeviceFlowAcceptance.swift'), /mcp-\\\(label\)-no-fleet-tools-in-list/);
});

test('W187c2 preview compares final changes and invite cancel follows explanatory text', () => {
  const session = read('DM/DeviceFlowSession.swift');
  const preview = session.split('enum DeviceFlowPreview')[1];
  assert.match(preview, /let after = proposal.preview/);
  assert.match(preview, /if old != new/);
  assert.match(preview, /原本：/); assert.match(preview, /改成：/);
  assert.match(preview, /單向：.*控制/);
  assert.doesNotMatch(preview, /互通 ↔|單向 →/);
  const cards = read('New/DeviceFlowCards.swift');
  const invite = cards.split('private var invite:')[1].split('@ViewBuilder private var pairingOutput:')[0];
  assert.ok(invite.indexOf('title: "取消"') > invite.indexOf('配對開啟後會公告'));
  const output = cards.split('@ViewBuilder private var pairingOutput:')[1].split('private func codeOutput')[0];
  assert.match(output, /if kind != \.invite \{ OSChipButton\(title: "取消"/);
});

async function mcpExchange(socketPath) {
  const child = spawn(process.execPath, ['Engines/os-mcp/server.mjs'], {
    env: { ...process.env, TATWO2_OS_SOCKET: socketPath, TATWO2_THREAD_ID: '00000001-3333-4333-8333-333333333333' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let output = '', error = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { error += chunk; });
  const exited = once(child, 'exit');
  const requests = [{ id: 1, method: 'tools/list' }, ...['fleet_overview', 'fleet_open_card', 'fleet_propose'].map((name, index) => ({
    id: index + 2, method: 'tools/call', params: { name, arguments: { callerThreadID: 'forged', userConfirmed: true } },
  }))];
  child.stdin.end(requests.map(row => JSON.stringify(row)).join('\n') + '\n');
  const timer = setTimeout(() => child.kill('SIGKILL'), 10_000);
  try {
    const [code] = await exited;
    assert.equal(code, 0, error);
    return output.trim().split('\n').map(line => JSON.parse(line));
  } finally { clearTimeout(timer); if (child.exitCode === null) child.kill('SIGKILL'); }
}

test('DM-07 MCP devices keep only selection/display fields even with an older full-record App', async () => {
  const root = mkdtempSync('/tmp/w187projection-');
  const socketPath = path.join(root, 'os.sock');
  const server = net.createServer(socket => {
    let input = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { input += chunk; });
    socket.on('end', () => {
      const request = JSON.parse(input);
      socket.end(JSON.stringify({ id: request.id, ok: true, result: { devices: [{
        id: 'fixture', name: 'fixture device', role: 'secondary', group: 'fixture group', online: true,
        host: '192.0.2.1', user: 'fixture', sshPort: 22, endpoints: [{ host: '192.0.2.1' }],
        hostKeyFingerprint: 'SHA256:fixture', clientKeyFingerprint: 'SHA256:fixture', workdirMap: { '/fixture': '/fixture' },
      }] } }) + '\n');
    });
  });
  try {
    server.listen(socketPath); await once(server, 'listening');
    const child = spawn(process.execPath, ['Engines/os-mcp/server.mjs'], {
      env: { ...process.env, TATWO2_OS_SOCKET: socketPath }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.stdin.end(['list_devices', 'os_status'].map((name, id) => JSON.stringify({
      id, method: 'tools/call', params: { name, arguments: {} },
    })).join('\n') + '\n');
    const [code] = await once(child, 'exit'); assert.equal(code, 0);
    for (const line of output.trim().split('\n')) {
      const row = JSON.parse(JSON.parse(line).result.content[0].text).devices[0];
      assert.deepEqual(Object.keys(row).sort(), ['group', 'id', 'name', 'online', 'role']);
      assert.equal(row.name, 'fixture device');
    }
  } finally { await new Promise(resolve => server.close(resolve)); rmSync(root, { recursive: true, force: true }); }
});

test('W187c2 external MCP with forged thread identity cannot list or call fleet tools; unavailable App fails closed', async () => {
  const root = mkdtempSync('/tmp/w187mcp-');
  const socketPath = path.join(root, 'os.sock');
  const server = net.createServer(socket => {
    let input = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { input += chunk; });
    socket.on('end', () => {
      const request = JSON.parse(input);
      assert.equal(request.method, 'fleet_overview', 'only the read-only native authorization probe is reached');
      assert.equal(request.params.callerThreadID, '00000001-3333-4333-8333-333333333333');
      assert.equal(request.params.userConfirmed, undefined);
      socket.end(JSON.stringify({ id: request.id, ok: false, error: 'caller_not_trusted' }) + '\n');
    });
  });
  try {
    server.listen(socketPath); await once(server, 'listening');
    for (const target of [socketPath, path.join(root, 'unavailable.sock')]) {
      const replies = await mcpExchange(target);
      assert.equal(replies.length, 4);
      const names = replies[0].result.tools.map(tool => tool.name);
      assert.equal(names.some(name => name.startsWith('fleet_')), false);
      assert.ok(names.includes('project_overview') && names.includes('computer_start'), 'existing tools remain registered');
      for (const reply of replies.slice(1)) {
        assert.equal(reply.result.isError, true);
        assert.match(reply.result.content[0].text, /^unknown_tool:fleet_/);
      }
    }
  } finally { await new Promise(resolve => server.close(resolve)); rmSync(root, { recursive: true, force: true }); }
});
