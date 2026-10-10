"""Assemble a disposable CEF fixture App from the previously verified local bundle."""
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
environment = repo.parents[1] / 'verify/W248b-webspace-222802/environment.txt'
settings = dict(line.split('=', 1) for line in environment.read_text().splitlines() if '=' in line)
template = json.loads(pathlib.Path(settings['TATWO2_W248_CEF_RECEIPT']).read_text())
scratch = pathlib.Path(tempfile.mkdtemp(prefix='w257-cef-app-', dir=sys.argv[1]))
app = scratch / 'W257.app'
subprocess.run(['/bin/cp', '-cR', str(pathlib.Path(template['binary']).parents[2]), str(app)], check=True)
binary = app / 'Contents/MacOS/Tatwo2'
shutil.copy2(repo / '.build/debug/Tatwo2', binary)
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info.update(CFBundleIdentifier='ai.tatwo.tatwo2.staging.w257', CFBundleName='W248', TatwoStagingRoot=str(scratch))
plist.write_bytes(plistlib.dumps(info))
shutil.copy2(repo / 'tests/fixtures/w257-timeline.py', app / 'Contents/Resources/w257-timeline.py')
for resource in (repo / '.build/debug').glob('*.bundle'):
    target = app / 'Contents/Resources' / resource.name
    # Existing cloned resources are archived before replacing with this build.
    if target.exists():
        target.rename(target.with_name(target.name + '.baseline'))
    shutil.copytree(resource, target)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(binary)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
# System shells strip DYLD_* before verify.sh launches its raw SwiftPM binary.
loader = (repo / '.build/debug/Tatwo2').resolve().parent.parent / 'Frameworks/Chromium Embedded Framework.framework'
loader.parent.mkdir(parents=True, exist_ok=True)
if not loader.exists():
    loader.symlink_to(app / 'Contents/Frameworks/Chromium Embedded Framework.framework')
receipt = pathlib.Path(sys.argv[1]) / 'fixture-app.json'
receipt.write_text(json.dumps({'binary': str(binary), 'scratch': str(scratch)}))
print(receipt)
