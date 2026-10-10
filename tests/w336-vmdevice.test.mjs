import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { runIsolated } from './helpers/w187-runtime.mjs';

const base = 'Engines/sandbox-agent/vm/';
const yaml = name => {
  const result = spawnSync('/usr/bin/ruby', ['-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))', base + name], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
};
test('both shipped Lima templates inherit every isolation field and run hardening as system provision', () => {
  const config = yaml('isolation.yaml');
  assert.equal(config.minimumLimaVersion, '2.2.0');
  assert.equal(config.vmType, 'vz');
  assert.equal(config.cpus, 4);
  assert.deepEqual(config.mounts, []);
  assert.equal(config.portForwards.length, 3);
  for (const [index, ip] of ['0.0.0.0', '127.0.0.1', '::'].entries()) {
    assert.equal(config.portForwards[index].guestIP, ip);
    assert.deepEqual(config.portForwards[index].guestPortRange, [1, 65535]);
    assert.equal(config.portForwards[index].ignore, true);
  }
  for (const field of ['forwardAgent', 'loadDotSSHPubKeys', 'forwardX11', 'forwardX11Trusted']) assert.equal(config.ssh[field], false, field);
  for (const field of ['system', 'user']) assert.equal(config.containerd[field], false, field);
  for (const [platform, image, memory, disk] of [['linux', 'ubuntu-26.04', '4GiB', '30GiB'], ['macos', 'macos-26', '8GiB', '80GiB']]) {
    const template = yaml(platform + '.yaml');
    assert.deepEqual(template.base, ['isolation.yaml', 'template:_images/' + image]);
    assert.equal(template.memory, memory); assert.equal(template.disk, disk);
    assert.equal(template.provision[0].mode, 'system');
    assert.equal(template.provision[0].file.url, platform + '.sh');
  }
  assert.equal(yaml('macos.yaml').video.display, 'default');
});
test('provision keeps work unprivileged and blocks host/LAN/loopback IPv4 and IPv6 while allowing only DNS exceptions', () => {
  const linux = readFileSync(base + 'linux.sh', 'utf8'), mac = readFileSync(base + 'macos.sh', 'utf8');
  for (const script of [linux, mac]) {
    for (const subnet of ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '127.0.0.0/8', 'fc00::/7', 'fe80::/10', '::1']) assert.ok(script.includes(subnet), subnet);
    assert.match(script, /192\.168\.5\.3.*53/);
    assert.doesNotMatch(script, /SUDO_ASKPASS|limactl|ssh |brew/);
    const result = spawnSync('/bin/bash', ['-n', base + (script === linux ? 'linux.sh' : 'macos.sh')]);
    assert.equal(result.status, 0);
  }
  assert.match(linux, /gpasswd -d work sudo/);
  assert.match(linux, /if ! command -v nft >\/dev\/null \|\| ! command -v python3 >\/dev\/null \|\| ! command -v git >\/dev\/null; then\n  apt-get.*\nfi/);
  assert.match(mac, /LIMA_HOME=.*NFSHomeDirectory/);
  assert.match(mac, /chmod 600 "\$LIMA_HOME\/password"; chmod 700 "\$LIMA_HOME"/);
  assert.match(mac, /if sudo -u work test -r "\$LIMA_HOME\/password"; then exit 1; fi/);
  assert.match(linux, /systemctl enable --now nftables/);
  assert.match(linux, /nft -f \/etc\/nftables.conf/);
  assert.match(mac, /dseditgroup -o edit -d work -t user admin/);
  assert.match(mac, /LaunchDaemons\/com.tatwo.pf.plist/);
  assert.match(mac, /<key>UserName<\/key><string>work<\/string>/);
  assert.match(mac, /sandbox-agent.py run --runner sh/);
  assert.match(mac, /<key>KeepAlive<\/key><dict><key>SuccessfulExit<\/key><false\/>/);
  const installer = readFileSync(base + 'install.sh', 'utf8');
  assert.match(installer, /id -un.*work/);
  assert.match(installer, /sandbox-agent.py" pair/);
  assert.match(installer, /sandbox-agent.py run --runner sh/);
  assert.doesNotMatch(installer, /--code|read_file|dispatch|run_command/);
});
test('fake limactl exercises discovery, list, start/stop, create, install with stdin code, authority, deadline and native UI', () => {
  const { root, output } = runIsolated('w336vmdevice');
  for (const name of ['missing-resource-no-fallback-no-download', 'configured-resource-missing-executable', 'highest-version-and-scoped-home', 'tatwo-only-platform-split', 'native-config-os-and-linux-default',
    'start-args-background-and-refresh', 'stop-args-background-and-refresh', 'create-both-platforms-template-args',
    'installation-work-account-pairing-code-stdin-only', 'no-code-in-argv-or-records-no-host-job-dispatch', 'non-primary-cannot-create-pairing',
    'bounded-background-process', 'immediate-starting-state-fable5', 'immediate-starting-state-aurora', 'create-platform-form-fable5', 'create-platform-form-aurora', 'two-rows-no-setup-fields-until-install-fable5', 'two-rows-no-setup-fields-until-install-aurora', 'install-setup-panel-non-primary-fable5', 'install-setup-panel-non-primary-aurora']) assert.ok(output.includes('PASS ' + name), name);
  const records = readFileSync(root + '/artifacts/fake-vm/argv.jsonl', 'utf8').trim().split('\n').map(JSON.parse);
  for (const { argv, home } of records) {
    assert.ok(home.endsWith('/fake-vm/lima-home'));
    assert.ok(['list', 'start', 'stop', 'create', 'copy', 'shell'].includes(argv[0]));
    assert.ok(!JSON.stringify(argv).includes('SYNTHETIC-STDIN-ONLY'));
  }
  for (const action of ['start', 'stop']) assert.ok(records.some(x => JSON.stringify(x.argv) === JSON.stringify([action, '--tty=false', 'tatwo-linux-ab12'])));
  for (const platform of ['linux', 'macos']) {
    const create = records.find(x => x.argv[0] === 'create' && x.argv.at(-1).endsWith('/vm/' + platform + '.yaml'));
    assert.match(create.argv[2], new RegExp('^--name=tatwo-' + platform + '-[a-f0-9]{6}$'));
  }
  const install = records.find(x => x.argv.includes('-u'));
  assert.deepEqual(install.argv.slice(0, 4), ['shell', '--workdir=/', 'tatwo-linux-ab12', 'env']);
  assert.match(install.argv[4], /^SUDO_ASKPASS=\/tmp\/tatwo-sandbox-install-[0-9A-F-]+\.askpass$/);
  assert.deepEqual(install.argv.slice(5, 11), ['sudo', '-A', '-H', '-u', 'work', 'sh']);
  assert.ok(records.some(x => x.argv.includes('rm') && x.argv.at(-1) === install.argv[4].slice('SUDO_ASKPASS='.length)), 'askpass removed after install');
  const source = readFileSync('App/Sources/Tatwo2/New/SandboxVirtualDevices.swift', 'utf8');
  assert.match(source, /DeviceFleetStore\.registerSandbox\(name: vm\.name/);
  const registration = readFileSync('App/Sources/Tatwo2/New/SandboxDevicesSection.swift', 'utf8');
  assert.match(registration, /static func registerSandbox[\s\S]*Task\.detached\(priority: \.utility\)/);
  assert.match(registration, /DeviceFleetStore\.registerSandbox\(name: chosenName/);
  assert.match(source, /sandboxLane\.allowed\(deviceID\)/);
  assert.match(source, /card\.displayCode == display/);
  assert.match(source, /要在這台的桌面開一次/);
  assert.doesNotMatch(source, /sandboxLane\.queue|\.dispatch\(|\/Users\/|\/Volumes\//);
});
