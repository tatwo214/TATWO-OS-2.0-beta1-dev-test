"""Run the complete existing w258download suite; retain its isolated HOME and artifacts."""
import json, os, pathlib, subprocess, sys, tempfile
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = pathlib.Path(tempfile.mkdtemp(prefix='d293-', dir=pathlib.Path(tempfile.gettempdir()).resolve()))
for directory in ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'tmp']:
    (root / directory).mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
paths = dict(HOME='home', CFFIXED_USER_HOME='home', TATWO_STAGING_SCRATCH_HOME='home',
    TATWO2_LIVE_ROOT='live', TATWO2_ENGINES_ROOT='engines', CODEX_HOME='engines/codex',
    TATWO2_CODEX_SOURCE_HOME='engines/codex', CLAUDE_CONFIG_DIR='engines/claude',
    CLAUDE_SECURESTORAGE_CONFIG_DIR='engines/claude', TATWO2_OS_SOCKET='o.sock',
    TATWO2_BROWSER_SOCKET='b.sock', TATWO2_OS_ROOT='os', TATWO_OS_ROOT='os',
    TATWO2_DOCS_ROOT='docs', TATWO2_OS_UPSTREAM_PATH='os/os-upstream.md', TATWO2_SKILLET_PATH='os/skillet.md', TMPDIR='tmp')
env.update({key: str(root / value) for key, value in paths.items()})
env.update(TATWO_STAGING_ROOT=str(root), TATWO2_SELFTEST='w258download', TATWO2_SELFTEST_ARTIFACTS=str(out))
if env.get('TATWO2_W293_TEST_INTERPOSER'):
    env['DYLD_INSERT_LIBRARIES'] = env['TATWO2_W293_TEST_INTERPOSER']
(out / 'isolated-root.json').write_text(json.dumps(dict(root=str(root), binary=sys.argv[2])))
with (out / 'w258download.log').open('w') as log:
    result = subprocess.run([sys.argv[2]], env=env, stdout=log, stderr=log, timeout=900)
print('w258download exit=' + str(result.returncode), flush=True)
sys.exit(result.returncode)
