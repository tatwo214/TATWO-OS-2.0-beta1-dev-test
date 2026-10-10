import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {testScratch} from '../helpers/test-scratch.mjs';
  const binary = process.env.TATWO2_TEST_BINARY;
  const cef = process.env.TATWO_CEF_ROOT;
  const receipt = process.env.TATWO2_W258_CEF_RECEIPT;
  assert.ok(binary && cef && receipt, 'CEF build and a scratch receipt are required; no stub coverage');
  const scratch = testScratch('w258-cef-app-');
  const bundle = path.join(scratch, 'W258.app');
  fs.mkdirSync(path.join(bundle, 'Contents/MacOS'), {recursive: true});
  fs.copyFileSync(binary, path.join(bundle, 'Contents/MacOS/Tatwo2'));
  const resources = path.join(bundle, 'Contents/Resources');
  fs.mkdirSync(resources, {recursive: true});
  for (const item of fs.readdirSync(path.dirname(binary)).filter(p => p.endsWith('.bundle'))) {
    fs.cpSync(path.join(path.dirname(binary), item), path.join(resources, item), {recursive: true});
  }
  fs.cpSync(new URL('../../Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists', import.meta.url),
    path.join(resources, 'BrowserBlocklists'), {recursive: true});
  const plist = {CFBundleExecutable:'Tatwo2', CFBundleIdentifier:'ai.tatwo.tatwo2.staging.w258',
    CFBundleName:'W258', CFBundlePackageType:'APPL', TatwoBrowserEngine:'chromium-cef', TatwoStagingRoot:scratch};
  fs.writeFileSync(path.join(bundle, 'Contents/Info.plist'), JSON.stringify(plist));
  const convert = spawnSync('/usr/bin/plutil', ['-convert', 'xml1', path.join(bundle, 'Contents/Info.plist')], {encoding:'utf8'});
  assert.equal(convert.status, 0, convert.stderr);
  const staged = spawnSync('/bin/bash', ['-c', `set -euo pipefail
source scripts/tatwo-cef-bundle.sh
tatwo_cef_stage_app_artifacts "$1" Tatwo2 "$2" "$3" W258 ai.tatwo.tatwo2.staging.w258 1.0 1 14.0 fixture fixture
tatwo_cef_sign_nested_artifacts "$1" - adhoc
/usr/bin/codesign --force --sign - "$1"
`, 'w258-stage', bundle, path.dirname(binary), cef], {encoding:'utf8', timeout:120000});
  assert.equal(staged.status, 0, staged.stdout + staged.stderr);
  // verify.sh launches the SwiftPM executable through /usr/bin/env, which strips DYLD_*.
  const loaderFramework = path.join(path.dirname(path.dirname(fs.realpathSync(binary))),
    'Frameworks/Chromium Embedded Framework.framework');
  fs.mkdirSync(path.dirname(loaderFramework), {recursive: true});
  if (!fs.existsSync(loaderFramework)) {
    fs.symlinkSync(path.join(bundle, 'Contents/Frameworks/Chromium Embedded Framework.framework'), loaderFramework);
  }
  fs.writeFileSync(receipt, JSON.stringify({binary:path.join(bundle, 'Contents/MacOS/Tatwo2'), scratch}));
