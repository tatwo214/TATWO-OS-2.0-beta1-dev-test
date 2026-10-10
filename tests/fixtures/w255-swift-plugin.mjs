// Studio's macOS 27 SDK needs the same plugin path for standalone swiftc as verify.sh uses for swift build.
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { basename } from 'node:path';
const plugin = process.env.TATWO_SWIFT_PLUGIN_PATH;
{
  for (const name of ['spawnSync', 'execFileSync', 'spawn', 'execFile', 'exec', 'execSync']) {
    const original = childProcess[name];
    childProcess[name] = function (file, args, ...rest) {
      const command = basename(String(file));
      const argv = Array.isArray(args) ? args : [];
      const wrapped = argv.find(arg => ['security', 'codesign'].includes(basename(String(arg))));
      const invoked = (command === 'xcrun' || command === 'env') && wrapped ? basename(wrapped) : command;
      const sign = argv.findIndex(arg => arg === '--sign' || arg === '-s' || /^--sign=|^-s.+/.test(arg));
      const identity = sign < 0 ? undefined : /^--sign=/.test(argv[sign]) ? argv[sign].slice(7) : /^-s.+/.test(argv[sign]) ? argv[sign].slice(2) : argv[sign + 1];
      const shell = ['exec', 'execSync'].includes(name) ? String(file) : ['sh', 'bash', 'zsh'].includes(command) ? String(argv[argv.indexOf('-c') + 1] ?? '') : '';
      const shellText = shell.replace(/["']/g, '');
      const shellKeychain = /(?:^|[\s;|&])(?:[^\s;|&]*\/)?security(?:[\s;|&]|$)/.test(shellText);
      const shellSign = shellText.match(/\bcodesign\b[^;\n]*?\s(?:--sign(?:=|\s+)|-s\s*)([^\s;]+)/);
      const shellSigner = shellSign && shellSign[1] !== '-';
      if (invoked === 'security' || shellKeychain || shellSigner || (invoked === 'codesign' && sign >= 0 && identity !== '-')) {
        const error = new Error('W255_BOUNDARY: real Keychain/signing call refused');
        if (name === 'spawnSync') return { status: 126, signal: null, stdout: '', stderr: error.message, error };
        throw error;
      }
      if (plugin && basename(String(file)) === 'swiftc' && Array.isArray(args) && !args.includes('-plugin-path')) {
        args = ['-plugin-path', plugin, ...args];
      }
      return original.call(this, file, args, ...rest);
    };
  }
  syncBuiltinESMExports();
}
