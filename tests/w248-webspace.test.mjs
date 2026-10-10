import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = 'App/Sources/Tatwo2/';

test('W267 web window shares Browser top chrome; native opt-out and DM keep their existing routes', () => {
  const page = read(app + 'Chat/ChatPage.swift');
  const panels = read(app + 'Chat/ChatPage+Panels.swift');
  const space = read(app + 'TAP/ChatGPTWebSpace.swift');
  assert.match(space, /mode == \.browser \|\| \(mode == \.chatgpt && isEnabled\)/);
  assert.match(page, /!isPanel && ChatGPTWebSpace.usesBrowserChrome\(model.mode\)/);
  assert.match(page, /managedByBrowser: usesBrowserTopChrome/);
  assert.match(page, /!usesBrowserTopChrome \|\| \(model.mode == \.browser && browserWorkSpaceStore.hoverRailShown\)/);
  assert.match(page, /model.mode == \.chatgpt && !ChatGPTWebSpace.isEnabled \{/);
  assert.match(panels, /ChatGPTWebSpacePane[^\n]*\n\s*\.ignoresSafeArea\(\.container, edges: isPanel \? \[\] : \.top\)/);
  assert.match(panels, /if !isPanel \{\s*BrowserChromeRevealHost\(reveal: webSpaceChromeReveal/);
  assert.match(panels, /\.onDisappear \{ if !isPanel \{ webSpaceChromeReveal.stop\(\)/);
  assert.match(read(app + 'Shell/AppShell.swift'), /if !ChatGPTWebSpace.usesBrowserChrome\(chatModel.mode\) \{\s*TatwoWindowPageRail/);
  // The shared DM pane cannot attach window chrome or ignore its sheet's safe area.
  assert.doesNotMatch(space, /BrowserChromeRevealHost|ignoresSafeArea|TatwoWindowDrag/);
});

test('web Space defaults on with native opt-out, keeps GPT selection, and uses a normal sibling under the Pod lease', () => {
  const space = read(app + 'TAP/ChatGPTWebSpace.swift');
  assert.match(space, /enabledKey = "tatwo.chatgpt.webSpace"/);
  assert.match(space, /object\(forKey: enabledKey\) as\? Bool\) \?\? true/);
  assert.match(space, /TatwoCEFContainerView/);
  assert.match(space, /mountBorrowedBrowser\(page\)/);
  assert.match(space, /dismantleNSView[\s\S]*detachBorrowedBrowser/);
  const sidebar = read(app + 'Chat/ChatPage+Sidebar.swift');
  assert.match(sidebar, /if ChatGPTWebSpace.isEnabled \{\s*Spacer\(minLength: 0\)\s*\} else \{\s*ChatGPTSpaceSidebarList[^}]*\}\s*workspaceSidebarFooter/);
  assert.doesNotMatch(space, /configurePod|runPodCommand|\.claim\(/);
  const pod = read(app + 'TAP/TapWebPod.swift');
  const sibling = pod.slice(pod.indexOf('func openSpacePage()'), pod.indexOf('func start(script:'));
  assert.match(sibling, /sharingContextWith: browser,[\s\S]*actor: \.human/);
  assert.doesNotMatch(sibling, /\.configurePod\(|prepareForRuntime/);
  assert.match(read(app + 'Chat/ChatPage+Panels.swift'), /if ChatGPTWebSpace.isEnabled \{[\s\S]*ChatGPTWebSpacePane[\s\S]*\} else \{[\s\S]*ChatGPTSpaceMainPane/);
  assert.match(read(app + 'Space/SpaceWorkspaceController.swift'), /if !ChatGPTWebSpace.isEnabled \{[\s\S]*if !spaces.allows\(\.chatgpt\)/);
  assert.match(read(app + 'TAP/ChatGPTTap.swift'), /transport.setSpaceVisible\(visible && !ChatGPTWebSpace.isEnabled\)/);
  // The existing selection and its mode route stay in the app shell.
  assert.match(read(app + 'Chat/ChatPage+Sidebar.swift'), /case \.chatgpt:/);
  assert.match(read(app + 'Chat/ChatPageConstants.swift'), /case "ChatGPT": self = \.chatgpt/);
});

test('stage a real CEF fixture App for the raw verify.sh selftest binary', () => {
  const binary = process.env.TATWO2_TEST_BINARY;
  const cef = process.env.TATWO_CEF_ROOT;
  const receipt = process.env.TATWO2_W248_CEF_RECEIPT;
  assert.ok(binary && cef && receipt, 'CEF build and a scratch receipt are required; no stub coverage');
  const scratch = testScratch('w248-cef-app-');
  const bundle = path.join(scratch, 'W248.app');
  fs.mkdirSync(path.join(bundle, 'Contents/MacOS'), {recursive: true});
  fs.copyFileSync(binary, path.join(bundle, 'Contents/MacOS/Tatwo2'));
  const resources = path.join(bundle, 'Contents/Resources');
  fs.mkdirSync(resources, {recursive: true});
  for (const item of fs.readdirSync(path.dirname(binary)).filter(p => p.endsWith('.bundle'))) {
    fs.cpSync(path.join(path.dirname(binary), item), path.join(resources, item), {recursive: true});
  }
  fs.cpSync(new URL('../Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists', import.meta.url),
    path.join(resources, 'BrowserBlocklists'), {recursive: true});
  const plist = {CFBundleExecutable:'Tatwo2', CFBundleIdentifier:'ai.tatwo.tatwo2.staging.w248',
    CFBundleName:'W248', CFBundlePackageType:'APPL', TatwoBrowserEngine:'chromium-cef', TatwoStagingRoot:scratch};
  fs.writeFileSync(path.join(bundle, 'Contents/Info.plist'), JSON.stringify(plist));
  const convert = spawnSync('/usr/bin/plutil', ['-convert', 'xml1', path.join(bundle, 'Contents/Info.plist')], {encoding:'utf8'});
  assert.equal(convert.status, 0, convert.stderr);
  const staged = spawnSync('/bin/bash', ['-c', `set -euo pipefail
source scripts/tatwo-cef-bundle.sh
tatwo_cef_stage_app_artifacts "$1" Tatwo2 "$2" "$3" W248 ai.tatwo.tatwo2.staging.w248 1.0 1 14.0 fixture fixture
tatwo_cef_sign_nested_artifacts "$1" - adhoc
/usr/bin/codesign --force --sign - "$1"
`, 'w248-stage', bundle, path.dirname(binary), cef], {encoding:'utf8', timeout:120000});
  assert.equal(staged.status, 0, staged.stdout + staged.stderr);
  // verify.sh launches the SwiftPM executable through /usr/bin/env, which strips DYLD_*.
  const loaderFramework = path.join(path.dirname(path.dirname(fs.realpathSync(binary))),
    'Frameworks/Chromium Embedded Framework.framework');
  fs.mkdirSync(path.dirname(loaderFramework), {recursive: true});
  if (!fs.existsSync(loaderFramework)) {
    fs.symlinkSync(path.join(bundle, 'Contents/Frameworks/Chromium Embedded Framework.framework'), loaderFramework);
  }
  fs.writeFileSync(receipt, JSON.stringify({binary:path.join(bundle, 'Contents/MacOS/Tatwo2'), scratch}));
});

test('CEF acceptance isolates storage and pins the existing staging loopback before startup', () => {
  const fixture = read(app + 'TAP/W248WebSpaceAcceptance.swift');
  assert.match(fixture, /child\.arguments = \["--use-mock-keychain"\]/);
  assert.match(fixture, /isolated\["TATWO_STAGING_BROWSER_LOOPBACK_PORT"\] = String\(port\)/);
  assert.ok(fixture.indexOf('try process.run()') < fixture.indexOf('try child.run()'));
  assert.doesNotMatch(fixture, /reply\(host ==/);
  const pod = read(app + 'TAP/TapWebPod.swift');
  assert.match(pod, /#if DEBUG[\s\S]*NativeStagingIsolation\.validationError\(env\) == nil/);
  assert.match(pod, /TatwoCEFProfileLocationResolver\.prepareForRuntime\(location\)/);
});
