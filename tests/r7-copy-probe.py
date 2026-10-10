"""R7 copy probe, extended from W187q: synthetic receiver, never a user App."""
from pathlib import Path
import json, shlex, subprocess, sys, tempfile

plan = json.loads(Path(sys.argv[1]).read_text())
code = r'''
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <unistd.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc == 1) {
            printf("%d\n", getpid()); fflush(stdout); [NSApp run]; return 0;
        }
        NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:atoi(argv[1])];
        NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:'W187' eventID:'fake'
            targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
        NSError *error = nil;
        [event sendEventWithOptions:(NSAppleEventSendNoReply | NSAppleEventSendNeverInteract) timeout:1 error:&error];
        printf("%ld\n", error ? (long)error.code : 0L); return 0;
    }
}
'''
with tempfile.TemporaryDirectory(prefix='r7-copy-', dir=plan['cwd']) as directory:
    base = Path(directory)
    copied, helper = str(base / 'synthetic-runner'), str(base / 'synthetic-events')
    subprocess.run(['/bin/cp', '/usr/bin/osascript', copied], check=True)
    (base / 'probe.m').write_text(code)
    subprocess.run(['/usr/bin/clang', str(base / 'probe.m'), '-framework', 'AppKit', '-framework', 'Foundation', '-o', helper], check=True, capture_output=True)
    for executable in [copied, helper]:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.tatwo.synthetic', executable], check=True, capture_output=True)
    target = subprocess.Popen([helper], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=plan['environment'])
    try:
        target_pid = target.stdout.readline().strip()
        assert target_pid.isdigit() and int(target_pid) == target.pid
        script = 'do shell script ' + json.dumps(shlex.quote(helper) + ' ' + target_pid)
        # The copied/resigned interpreter and the sender's event only address this owned receiver.
        control = subprocess.run([copied, '-e', script], cwd=plan['cwd'], env=plan['environment'], capture_output=True, text=True, timeout=10)
        assert control.returncode == 0 and control.stdout.strip() == '0', (control.returncode, control.stdout, control.stderr)
        literal = subprocess.run(['/usr/bin/sandbox-exec', *plan['arguments'][:-1], copied, '-e', 'return "synthetic"'], cwd=plan['cwd'], env=plan['environment'], capture_output=True, text=True, timeout=10)
        assert literal.returncode == 0 and literal.stdout.strip() == 'synthetic', (literal.returncode, literal.stderr)
        probe = subprocess.run(['/usr/bin/sandbox-exec', *plan['arguments'][:-1], copied, '-e', script], cwd=plan['cwd'], env=plan['environment'], capture_output=True, text=True, timeout=10)
        denied = probe.returncode == 0 and probe.stdout.strip() != '0' and probe.stdout.strip().lstrip('-').isdigit()
        print('R7-CARDS-04 ' + ('PASS' if denied else 'FAIL') + ' copied-resigned-osascript Apple Events: event status=' + probe.stdout.strip())
        raise SystemExit(0 if denied else 1)
    finally:
        target.terminate(); target.wait(timeout=5)
