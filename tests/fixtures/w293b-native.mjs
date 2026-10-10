import assert from 'node:assert/strict';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
export function compileLauncher(directory, header) {
  const dylib = join(directory, 'tatwo2-staging-keychain.dylib');
  for (const args of [
    ['-dynamiclib', '-Wno-deprecated-declarations', 'script/tatwo2-staging-keychain.c', '-framework', 'Security', '-Wl,-install_name,@executable_path/tatwo2-staging-keychain.dylib', '-o', dylib],
    ['-include', header, 'script/tatwo2-staging-launcher.c', '-Wl,-needed_library,' + dylib, '-o', join(directory,'Tatwo2Staging')],
  ]) {
    const result = spawnSync('clang', args, {encoding:'utf8'});
    assert.equal(result.status, 0, result.stderr);
  }
  return dylib;
}
