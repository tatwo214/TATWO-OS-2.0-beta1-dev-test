#!/usr/bin/env python3
# Copy this launcher to an evidence snapshot before running it.
import os
from pathlib import Path
import subprocess
import sys

repo = Path.cwd()
evidence = Path(sys.argv[1]).resolve()
evidence.mkdir(parents=True, exist_ok=True)
for suite in ('w208tap', 'w185tap', 'w183connect', 'w292'):
    root = evidence / suite
    env = os.environ.copy()
    paths = {
        'TATWO_STAGING_ROOT': root,
        'HOME': root / 'home',
        'CFFIXED_USER_HOME': root / 'home',
        'TATWO_STAGING_SCRATCH_HOME': root / 'home',
        'TATWO2_LIVE_ROOT': root / 'live',
        'TATWO2_ENGINES_ROOT': root / 'engines',
        'CODEX_HOME': root / 'engines/codex',
        'TATWO2_CODEX_SOURCE_HOME': root / 'engines/codex',
        'CLAUDE_CONFIG_DIR': root / 'engines/claude',
        'CLAUDE_SECURESTORAGE_CONFIG_DIR': root / 'engines/claude',
        'TATWO2_OS_SOCKET': root / 'os.sock',
        'TATWO2_BROWSER_SOCKET': root / 'browser.sock',
        'TATWO2_OS_ROOT': root / 'os',
        'TATWO2_DOCS_ROOT': root / 'os/docs',
        'TATWO2_OS_UPSTREAM_PATH': root / 'os/os.md',
        'TATWO2_SKILLET_PATH': root / 'os/skillet.md',
        'TATWO2_SELFTEST_ARTIFACTS': root / 'artifacts',
    }
    for key, path in paths.items():
        env[key] = str(path)
        if key.endswith('SOCKET') or key.endswith('PATH'):
            path.parent.mkdir(parents=True, exist_ok=True)
        else:
            path.mkdir(parents=True, exist_ok=True)
    env['TATWO2_SELFTEST'] = suite
    env['TATWO2_SELFTEST_NODE'] = str(Path(subprocess.check_output(['which', 'node'], text=True).strip()))
    with (evidence / (suite + '.log')).open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Tatwo2')], env=env, stdout=out, stderr=subprocess.STDOUT, timeout=180)
    lines = (evidence / (suite + '.log')).read_text().splitlines()
    print(suite, 'exit=' + str(result.returncode), 'PASS=' + str(sum(' PASS ' in line for line in lines)), flush=True)
    for line in lines:
        if 'SUMMARY' in line or ' FAIL ' in line:
            print(line, flush=True)
    if result.returncode:
        sys.exit(result.returncode)
