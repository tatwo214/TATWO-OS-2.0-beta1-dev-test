原報告的 22 項：同一安全環境下兩版均 FAIL；20 項需真鑰匙圈，被測試入口攔截，另兩項缺既有 fixture/helper。
|測試名|基準 863a6b0c|W255 5fb8053d|判定|
|---|---|---|---|
|dry-run preserves external runtime HOME and pinned fixed signing identity|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse accepts a /tmp alias in declared receipt path without changing any bytes|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse rejects a genuinely different declared bundle path without changing the slot|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse Grok hash mismatch fails closed without executing the trap runtime|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|legacy signed plist preserves the vendor version through its exact wrapper-version pin|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse Grok missing pins, symlinks, and bundle escapes fail closed without execution|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse actual model-runtime resolution copies only signed pinned Grok bytes without probing them|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|stale reuse plist Chat workdir fails closed without an explicit current-root override|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|explicit current-root override retargets a stale reuse plist without changing the fixed slot|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|ad-hoc reuse fails closed before an unapproved signing migration|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|explicit ad-hoc to fixed identity migration reports one-time TCC reauthorization|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse preserves a receipt-pinned Chromium engine when --enable-cef is omitted|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse rejects an unapproved WebKit to Chromium engine migration|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|reuse rejects an unpinned legacy receipt without explicit Chromium migration|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|explicit migration upgrades an unpinned legacy receipt to Chromium|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|same-slot preflight rejects a second top-level App|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|real five-helper CEF bundles pass production verification while direct otool reproduces the parenthesized executable truncation|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|owned synthetic model runtime only answers --version and traps actual execution|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|same-slot storage is repo-owned and insufficient build space fails closed|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|real same-slot swap commits, verifies signing, then injected post-receipt failure rolls back bytes and Contents|FAIL|FAIL|兩版安全攔截；不能據此判定產品缺陷|
|W81 real GBrain (W180 E4 production path): archive same-slug page whole → write → refuse changed page → restore old page + title|FAIL|FAIL|基準亦失敗；未修產品|
|actual Swift registry + Island: fixture detection, dedupe, persistence and user-approved open|FAIL|FAIL|基準亦失敗；未修產品|
