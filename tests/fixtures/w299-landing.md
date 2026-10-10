# W299 landing on preview/027

Base: `8e948a5b`. No fetch, push, live account or website access.

- F1 `bf81f168` is already an ancestor of the base. CU policy, dispatch hardening and its fake-backend acceptance remain in the current source. No duplicate cherry-pick.
- F2 `6dc71b8a` is already an ancestor of the base. Items 7–13 remain in the current source. W207 already replaced the legacy-only `HandsTapMap.name` with `TapProjectMapStore.displayMap`; native checks now cover current-only and current-before-legacy display without mutation.
- Public privacy fixtures identified in the old F1/F2 reports were already replaced upstream. Imported W222 synthetic project names and upstream W294f evidence account paths are normalized to generic fixture terms. Original W294f evidence is preserved in the external task evidence folder. The scanner and its policy are unchanged.
- W222 `94131e6e` / `4c6f613b` / `a93a12e6` plus W222c `7522c339` / `35b59098` / `b9f243b9` / `b4fb3092` / `3c38819c` are integrated as their final combined tree delta against `bc42047e`.
- Preserve the current `ChatGPTTap.sleep` and omit superseded dots cleanup. Preserve current managed-conversation guard checks and model routing.
- W222c-5 superseded W222's unused product rename/restore methods. Do not restore orphan methods or build a second project UI: current project-space rename/archive/restore continues to act on space records. The retained rename helper is opt-in by the existing defaults key and still requires a real-account compatibility check. Acceptance changes isolated documents to exercise the retained helpers; no claim of product UI completion.
- Per-turn guarded mappers now wait for the engine mapper's lifecycle writes and retain its folder-specific failure gate. A native regression recovers the file without clearing the gate and checks that guarded dispatch still refuses; another checks that unrelated dispatch works and queued archive routes to inbox.
- The Node selftest locator uses PATH then the bundled runtime. In isolated w183ui/w185tools only, a Node inside the account home is copied to an owned private temporary directory and removed by defer. The production sandbox and home/volume refusal rules are unchanged.
- Dictation's original w184chat gate remains required. A screen-lock failure stays a failure and must be rerun unlocked. CEF skips and website/account checks remain separate limitations.

The room guard counts product files excluding `tests/` and `*Acceptance.swift`, as defined by the supplied script. Raw verification logs and immutable script snapshots live under the task's external `tatwo-build/verify` evidence folders.

Final verification also supplies a private temporary runtime copied from PATH for the gateway fixtures. W183 gateway staging checks follow W276 bundle identity. The safety-lock fixture forces both rename and atomic write to refuse with a directory placeholder, removes that placeholder, then checks the read-only armed marker and lock persistence across restart. The W183 one-press source assertion now requires the upstream account epoch guard. W292 may write receipts to an external directory so live test output does not overwrite exported historical fixtures.
