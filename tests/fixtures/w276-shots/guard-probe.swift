import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let id = Bundle.main.bundleIdentifier!
let candidates = NSRunningApplication.runningApplications(withBundleIdentifier:id)
let siblings = candidates.filter { $0.processIdentifier != getpid() }
fputs("GUARD_PROBE self=\(getpid()) records=\(candidates.map { $0.processIdentifier }) other=\(siblings.map { $0.processIdentifier })\n",stderr)
if siblings.isEmpty {
    DispatchQueue.main.asyncAfter(deadline: .now()+2) { fputs("GUARD_PROBE normal_exit\n",stderr); app.terminate(nil) }
    app.run()
} else { fputs("GUARD_PROBE early_return\n",stderr) }
