F1：完整 tests/*.test.mjs；共同 410 檔，W255 另新增 1 檔／3 項。原始 TAP、環境 JSON、清單與序列對照保存在房間外證據目錄。
同一 Node、並行度 4、TMPDIR=<room-evidence>/staging/tmp/full/、同一合成 HOME／live／engines／OS 與 W255 原版 preload；只有受測 binary 路徑不同。
基準：2947 tests，2831 PASS／105 FAIL／11 SKIP；W255：2950 tests，2831 PASS／108 FAIL／11 SKIP。9 項差異在未改碼前逐項序列重跑，兩版各 9 PASS／0 FAIL／0 SKIP；其餘 FAIL 不修產品。
僅一個 fixture 欄位名稱因 public-privacy 掃描規則遮蔽；未改測試或原始外部證據。
F1：共同 410 檔同環境；W255 另增 1 檔／3 測試。全套並行度 4；差異 9 項另以並行度 1 單獨重跑，兩版均 9 pass／0 fail／0 skip。

|測試名|基準 863a6b0c|W255 5fb8053d|判定|
|---|---|---|---|
|(a) round 2: raising the central level L1 → L2 does not widen a grant that was made at L1 (real tool calls in the self-test)|PASS|PASS|一致|
|(a) the effective scope is the central setting (level) + every project on the host — no intersection with the local approval; revocation still immediate|PASS|PASS|一致|
|(b) every project is visible (new ones included); trading projects (one constant list) are at most L0 — L1/L2 tools are refused on the host|PASS|PASS|一致|
|(b) round 2: trading projects are classified by the folder's real identity (realpath, device+inode, shared git repository) — any name that hits makes every alias L0; the classification is versioned, running work is cancelled on a change, submit re-checks the version|PASS|PASS|一致|
|(c) every tool that reads blocks key files, at every level: project read/list/search, workspace read/list/search, git status/diff, the workspace export|PASS|PASS|一致|
|(c) one key-file list: the App (Swift) and the file helper (fsop.mjs) carry the same names, prefixes, suffixes and folders|PASS|PASS|一致|
|(c) round 2: a project whose root folder itself is a key folder (.aws, credentials-backup…) is out of scope entirely|PASS|PASS|一致|
|(c) round 2: every source that enters a workspace is filtered — dependencies too (their .git and key files go; .build/repositories never comes)|PASS|PASS|一致|
|(c) round 2: run_command and long jobs are denied by the sandbox rule itself (real sandbox-exec): no reading, no writing, no creating key files anywhere in the workspace; look-alikes and metadata still work|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|(c) round 2: the list also has wallets, secret*/secrets/.secrets, api keys, service accounts, mnemonic/seed, *.tfvars — in both copies|PASS|PASS|一致|
|(c) round 3: an old workspace is tidied before its first use — key files, other repositories' .git and old .build/repositories are quarantined whole (moved, restore notes written first, never deleted); its own .git is archived and rebuilt clean (no reflog, no unreachable objects); every move is fd-relative and never follows a link; one tidy at a time|PASS|PASS|一致|
|(c) round 4: after a restore (RESTORE.txt) the workspace is locked and re-tidied before any use — a re-appeared .build/repositories or a replaced root .git (fingerprint) invalidates the tidy; the tidy pauses (lock + one sentence) instead of rebuilding over staged, partly staged or conflicted work; restore notes tell the truth|PASS|PASS|一致|
|(c) the file helper refuses every key file (read, list, search, any case, any depth) and still serves the look-alikes|PASS|PASS|一致|
|(c) the git pathspecs and the export find expression really exclude key files (real git, real find; same construction as HandsFloors.swift)|PASS|PASS|一致|
|(d) the connect card has no project layer and no "go tick in ChatGPT build" hint; ［連線］ starts right away; the consent line sits next to it|PASS|PASS|一致|
|(e) auto-tick: only the one known box, by CEF's node-verified native (isTrusted) click on the same document, once; a consent text that is not a verified version, an unknown checkbox or a moved box goes to the user with one sentence|PASS|PASS|一致|
|(f) auto-fill only on the bound page that the press opened (anchor first, then the page; same page, same parameters, this host); anything else = no fill, no code, the transaction is void|PASS|PASS|一致|
|(g) a failed, unaccepted or unproven auto-fill falls back to showing the code (one sentence on the card); never a second fill|PASS|PASS|一致|
|+add is local; shared rows support toggle, reorder, rename and explicit builder|PASS|PASS|一致|
|.git symlinks are rejected before exclusion|PASS|PASS|一致|
|/goal 101 (user 09-19): truly floating chips, instant retract, fading glass, copy-link button, hover toolbox|PASS|PASS|一致|
|/goal 101: chat panel renders with its own runtime and never touches standalone Browser state|PASS|PASS|一致|
|/goal 101: chat-side address editing is inline in the toolbar row, not a floating panel over the page|PASS|PASS|一致|
|/goal 101: operating TATWO OS itself never deadlocks the grant lock and survives its own mode switch|PASS|PASS|一致|
|/goal 101: real mouse clicks reach the chat strip and the panel toolbar while the panel is docked|PASS|PASS|一致|
|/goal 101: self-targeted AX work runs on the main thread, other Apps stay off it|PASS|PASS|一致|
|/goal 102 G1/G2: chat-side tabs and open state follow the thread; docked panel leaves room for the composer|PASS|PASS|一致|
|/goal 102: chat stop needs no confirmation, swaps to send while typing, and has a forced fallback|PASS|PASS|一致|
|1 existing native context is appended with group data after ultrawork|PASS|PASS|一致|
|1. self-target AX actions run from a main run-loop block with a cancellable identity, never inside a GCD main-queue block or the session lock|PASS|PASS|一致|
|1. while a self AX action is still inside a menu or dialog, nothing calls AX in-process: observe says busy, only keys go through; open menus are read|PASS|PASS|一致|
|10: timed and condition callbacks execute after unlock|PASS|PASS|一致|
|11: recovery writes to damaged month and write failures cannot abort query|PASS|PASS|一致|
|1: programmatic sends default to system, composer and dispatch are explicitly scoped|PASS|PASS|一致|
|2 route requires a real local thread and applies the existing trading classifier|PASS|PASS|一致|
|2. the queued self action re-verifies grant, connection, context, full access and sensitive page at run time; revocation voids the queue; the permission setter revokes synchronously|PASS|PASS|一致|
|2./5. window picking: three-valued protection + shield veto, usable on every branch, no window number = refused before read (image or not), one output filter for success and error|PASS|PASS|一致|
|20 reconnect cycles use one connector; transient failures never press Connect and expired authorization reuses its ID|PASS|PASS|一致|
|2: foreground routing checks page, mode, key window and DM target|PASS|PASS|一致|
|3 facade cannot automatically relay TAP input into a writable Coder turn|PASS|PASS|一致|
|3+ real Swift group regression cases|PASS|PASS|一致|
|3. the direct (NSAccessibility) route needs element identity inside the node's own window, exactly one match, re-resolved at run time|PASS|PASS|一致|
|3: both journal phases share the callID and event append deduplicates IDs|PASS|PASS|一致|
|4. event targets: every synthesized event goes to a window resolved by number (observed window, a menu's own window, a popover's own window); unresolved = refused; no point search anywhere|PASS|PASS|一致|
|4: turn terminal takes actual turnID and tracks active turns|PASS|PASS|一致|
|5: workspace resolves its project; thread and workspace remain separate|PASS|PASS|一致|
|6. executable self-test w184cu: registered, DEBUG only, real menus through production paths, the counterexamples for findings 1–5, watchdog; C4 stays a SKIP that is not completion|PASS|PASS|一致|
|6: event storage never reads the conversation document|PASS|PASS|一致|
|7: hot hooks use engine messages without transcript copies|PASS|PASS|一致|
|8: events reuse local device identity|PASS|PASS|一致|
|9: bounded shutdown flush is attached to termination|PASS|PASS|一致|
|A four forms: sizes, ⌘⌥Tab order, old expand sizes mapped, remembered; docked and floating boxes follow the form|PASS|PASS|一致|
|A2 W184 F3 corner radius fixed: the box is 52 in every form and size (no scaling), the composer 40 and concentric|PASS|PASS|一致|
|A2 sidecar startup awaits background selection; main-thread reuse reads only the snapshot|PASS|PASS|一致|
|A3 Release compilation of all .052-added acceptance files emits no acceptance symbols|PASS|PASS|一致|
|A3 every .052-added acceptance declaration is inside a complete DEBUG boundary|PASS|PASS|一致|
|A3 header (W184 AB/F): only the current page circle top-left (⋯ and ⌄ gone; their menu is the circle's right-click menu); no name row; the session picker still opens in the body|PASS|PASS|一致|
|A3 icon order: assistant, ChatGPT, Coder, recent sessions, later (Bot team, LINE), direct keys|PASS|PASS|一致|
|A3 icon strip scrolls horizontally (trackpad and mouse wheel) with fading ends|PASS|PASS|一致|
|A3 icons: same avatar on a glass circle, accent ring when selected, device mark, later icons grey|PASS|PASS|一致|
|A4 each target has its own model path and a pick changes only that target|PASS|PASS|一致|
|A4 model chip sits in the composer toolbar, next to send (W181: the DM's own capsule chip)|PASS|PASS|一致|
|A5／B3 inner landscape: one top bar over two columns; left = this chat (same view in every form), right = Browser or the other chat|PASS|PASS|一致|
|App delegate refreshes once before services, logs once without a dialog|PASS|PASS|一致|
|App packaging embeds the clean-room project|PASS|PASS|一致|
|AppDelegate installs and uninstalls monitor; executable self-test covers required sequences|PASS|PASS|一致|
|Automatic device reconnect and synchronization cannot emit hints or Island notices|PASS|PASS|一致|
|B page circle menu (was ⋯): four forms (current ticked) with ⌘⌥Tab, direct keys, ⌥⌘ and the accessibility item, collapse / restore; a system menu|PASS|PASS|一致|
|B top bar: only the current page circle top-left (hover opens right; right-click / control-click = the menu); no ⋯, ⌄, ✕, size button, name row or ⌥⌘ line|PASS|PASS|一致|
|B ⌘⌥Tab: Carbon hotkey only while the box shows, released when folded; one step per finished transition; failure said in the page circle menu|PASS|PASS|一致|
|B1 fake MCP child proves fragment exclusion in both engine configurations|PASS|PASS|一致|
|B3 cleaner only touches the App clone folder and keeps the newest and the running copy|PASS|PASS|一致|
|B3 runs once per installed build, after the App has been up for a while, off the main thread; one log line|PASS|PASS|一致|
|B4 tokens: the shell only uses DMPhone numbers (fonts 17/15/13/11, 44 touch, concentric corner fixed at 52)|PASS|PASS|一致|
|Background notice refresh cannot connect, enable, modify settings or revoke credentials|PASS|PASS|一致|
|Bot page no longer re-renders on every DM keystroke|PASS|PASS|一致|
|Bot tab hides its own round button only while the global DM is enabled|PASS|PASS|一致|
|Bot unpinned rail control reserves the native traffic-light cluster|PASS|PASS|一致|
|BotPage files exist as a sibling surface, not ChatPageModel|PASS|PASS|一致|
|Browser hover is independent of Chat pin preference and resets at lifecycle boundaries|PASS|PASS|一致|
|B／A4 queued entries (GPT-6 re-check new findings 1–3): the whole entry is one request — cancellable, re-checked before dequeue, the final box state from its own completion|PASS|PASS|一致|
|B／A4 tent never swallows "show me this" entries: direct keys, 到私訊框設定, DMBrowser.reveal, the ［連線］ card stand the phone up first; queued during a transition|PASS|PASS|一致|
|C W184 F3 the slide runs on the render server: a layer stage with the same critically damped spring; only position, size and opacity animate; corner fixed at 52|PASS|PASS|一致|
|C every form change slides (W184 F2): a critically damped spring (.smooth(duration: 0.42)), pure functions of time; no 3D, scale, rotation or clip keyframes|PASS|PASS|一致|
|C native pages (CEF) follow a mask held for the whole transition: moved or newly attached pages hidden too; all shown at the end; never reloaded|PASS|PASS|一致|
|C observable form state for other rooms: current form, transition flag, setForm(_:animated:)|PASS|PASS|一致|
|C tokens: every number comes from DMPhone (fonts 17/15/13/11, 36 circles, 32 chips, concentric 52 − 12)|PASS|PASS|一致|
|C1 message list: my bubble right and at most 78%, replies full width with no avatar, bottom-aligned, 18 apart|PASS|PASS|一致|
|C1 rows keep everything: Markdown, error card, system notes (13pt in the DM), typing dots, the offline mark|PASS|PASS|一致|
|C2 behavior unchanged: Return / Shift-Return / IME, ⌘V and drops, attachment chips, disabled chips, drafts|PASS|PASS|一致|
|C2 glass capsule composer: 12 from the edges, 12/12/10/16, corner 40, two layers, ＋ … memory, model, send/stop|PASS|PASS|一致|
|C2 the ChatGPT line sits above the composer, centered, with a lock — only when the target is ChatGPT|PASS|PASS|一致|
|C3 notice rows: one plain sentence + at most one glass chip; approval stays in the Island|PASS|PASS|一致|
|C3 project ID validation, no guessing/auto-create, workspace consistency, journal not dialogue|PASS|PASS|一致|
|CARDS-03 and REV-05 progress never promises automatic admission for pending pairing|PASS|PASS|一致|
|CARDS-03 existing pending rows are included in the invitation baseline|PASS|PASS|一致|
|CEF pin, bridge, helper, and backend are present and not ignored candidates|PASS|PASS|一致|
|CEF staging contract is explicit, fail-closed, cache-isolated, and cleans generated work|PASS|PASS|一致|
|CLI --json with fixture roots does not touch production paths|PASS|PASS|一致|
|CLI and MCP exchange an App-issued revision host authorization without minting it|PASS|PASS|一致|
|CLI help and parser expose revise while start and stop use safe session APIs|PASS|PASS|一致|
|CLI invoked through a symlinked path still runs and reports|PASS|PASS|一致|
|CLI project menus, transcript history and remote sidebar exclude the assistant home|PASS|PASS|一致|
|CLI readiness is before the existing native guards/build, with original budgets added|PASS|PASS|一致|
|CLI readiness: errors and missing readings cannot authorize compilation|PASS|PASS|一致|
|CLI readiness: invalid/below-threshold pressure resets consecutive samples|PASS|PASS|一致|
|CLI readiness: invalid/below-threshold systemKiB resets consecutive samples|PASS|PASS|一致|
|CLI readiness: invalid/below-threshold workKiB resets consecutive samples|PASS|PASS|一致|
|CLI readiness: one good sample or a late second sample is not sufficient|PASS|PASS|一致|
|CLI readiness: permanent invalid reading/probe failure remains a detailed failure|PASS|PASS|一致|
|CLI readiness: recovery requires two consecutive exact-threshold samples|PASS|PASS|一致|
|CLI readiness: timeout reports last actual values, unchanged thresholds and deadline|PASS|PASS|一致|
|CLI resource probes: correct volumes, cwd and shared deadline; no shell/compiler|PASS|PASS|一致|
|CLI resource probes: expired deadlines do not spawn, command failures stay invalid|PASS|PASS|一致|
|CLI workbench native fixture: layout, actions and fixed visual set|SKIP|SKIP|一致|
|CLI workbench preflight: exact thresholds (no compiler)|PASS|PASS|一致|
|CLI workbench preflight: memory critical (no compiler)|PASS|PASS|一致|
|CLI workbench preflight: memory warning (no compiler)|PASS|PASS|一致|
|CLI workbench preflight: mini system space (no compiler)|PASS|PASS|一致|
|CLI workbench preflight: system threshold minus one (no compiler)|PASS|PASS|一致|
|CLI workbench preflight: work threshold minus one (no compiler)|PASS|PASS|一致|
|CLI workbench presentation has one action seam and no runtime or store dependency|PASS|PASS|一致|
|CU hardening uses trusted app categories, protected paths, paste and per-dispatch approval gates|PASS|PASS|一致|
|CU never uses internal auto-allow/cache/self target; host Island click required and lease <=15m|PASS|PASS|一致|
|CU restrictions are layered, native preflight before background and foreground input, capture gates untouched|PASS|PASS|一致|
|CUT-06 removed permission does not revoke live colleague transport|PASS|PASS|一致|
|CUT-07 endpoint sweep is TATWO-only and bounded|PASS|PASS|一致|
|Chat uses the user home fallback until a configured or restored project wins|PASS|PASS|一致|
|Chat 固定鈕：搬到左上（同 Browser 字形與尺寸），右上不再有；拖曳區讓出那一格|PASS|PASS|一致|
|ChatGPT Space 09-25 \#125: top-right controls live in the traffic-light row, no extra header band in the window|PASS|PASS|一致|
|ChatGPT Space 09-25 \#126: image zoom reuses Coder's image preview (tap blank or Esc closes, fit ratio, download, gallery)|PASS|PASS|一致|
|ChatGPT Space 09-25 \#127: conversation images follow the web width rule and a 400pt height cap|PASS|PASS|一致|
|ChatGPT Space 09-25: clickable plugins, native detail page, zh-Hant via the global translation index, ChatGPT attachment tiles|PASS|PASS|一致|
|ChatGPT Space 09-25: faster loading — parallel refresh, in-memory conversation cache, hover prefetch, launch prewarm|PASS|PASS|一致|
|ChatGPT Space 09-25: no title top-left, Chinese composer, web-exact effort card, temporary chat top-right, photos drop and paste, ChatGPT typography|PASS|PASS|一致|
|ChatGPT Space 09-25: translation keeps brand and tech terms, uses Taiwan wording, tool names stay English, detail opens at top|PASS|PASS|一致|
|ChatGPT Space mirrors the web: layered + menu, Library, sources, switch-model retry, temporary chats stay out of the list|PASS|PASS|一致|
|ChatGPT Space: edit/copy own messages, version switch, new chat inside a project|PASS|PASS|一致|
|ChatGPT Space: settings icon stays accessible, healthy states are silent, actionable states alone show a marker|PASS|PASS|一致|
|ChatGPT Space: temporary chats flag every message; library zoom starts from the thumbnail; markdown files render as markdown|PASS|PASS|一致|
|ChatGPT Space: you can browse other conversations while a long answer runs; an old send cannot pull the view back|PASS|PASS|一致|
|ChatGPT target uses one resident ChatGPTConversationSession, leases only while shown, and writes nothing|PASS|PASS|一致|
|ChatGPT tool descriptions explain scope, paging and creation semantics|PASS|PASS|一致|
|ChatPage .bot branch does not call send|PASS|PASS|一致|
|ChatPageModel real send explicitly routes TAP before any CLI login check|PASS|PASS|一致|
|ChatPageModel：isEngineDisabled＝送不出（新判斷），isAPIKeyOptedOut＝有勾；助理、私訊框、匯入都吃新判斷|PASS|PASS|一致|
|Claude attachment-only request contains an image, not an empty text block|PASS|PASS|一致|
|Cloudflare accounts: shared store, keychain ThisDeviceOnly without an all-apps ACL, list file holds only ids and names|PASS|PASS|一致|
|Coder minimap uses visible rows and centers sparse and overflowing histories|PASS|PASS|一致|
|Coder row opens project journal and existing transcript, map only when valid; selftest registered|PASS|PASS|一致|
|Coder shared pieces untouched: the DM wraps its own send/stop/row; ChatComposerChrome keeps its 28pt buttons|PASS|PASS|一致|
|Coder: an offline thread opens read-only (cached content or a plain note); the composer becomes a note + glass chip|PASS|PASS|一致|
|Codex explicitly managed empty registry cannot be reseeded from another home|PASS|PASS|一致|
|Codex forwards bare keys, TOML fields and merged inherited/alias env to MCP child|PASS|PASS|一致|
|Computer Use 的授權說明變成那一頁的副標，不再是設定頁外層自己補的一行|PASS|PASS|一致|
|D tokens: the numbers come from the approved mock and from DMPhone (no hard-coded sizes in the views)|PASS|PASS|一致|
|D1 (W184 G2d) the page fills the Browser (12 margins, no handle strip); the sidebar and toolbar are the Browser space's, hidden until the pointer reaches the left / top edge|PASS|PASS|一致|
|D1 D6 D13 production Swift launch recovery preserves post-rename candidate and refuses invalid backups|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|D1 D6 D13 production Swift launch recovery preserves post-rename candidate and refuses invalid backups [#2]|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|D1 Tatwo Island 重設 is a glass chip; the island settings page has no system buttons|PASS|PASS|一致|
|D1 cold-start screen retries with a glass chip, not the blue system button|PASS|PASS|一致|
|D1 glass chip looks disabled when disabled, and red when destructive|PASS|PASS|一致|
|D1 inventory: system dialogs still on settings cards are exactly the listed ones|PASS|PASS|一致|
|D1 post-rename SIGKILL keeps verified new destination; launch failures do not roll back|PASS|PASS|一致|
|D1 post-rename SIGKILL keeps verified new destination; launch failures do not roll back [#2]|PASS|PASS|一致|
|D1 scanner finds unstyled Buttons and skips styled ones, chips, menus and dialog actions|PASS|PASS|一致|
|D1 sweep: settings cards have no system-framed buttons left (bordered or unstyled)|PASS|PASS|一致|
|D1 設定 › OS › 記憶「接上 N 個」asks in the same card row before linking|PASS|PASS|一致|
|D1 設定 › OS: a confirm row left open does not outlive what it asks about|PASS|PASS|一致|
|D1 設定 › OS: rules 接上 confirms inside the card with neutral glass chips|PASS|PASS|一致|
|D10 actual live/plans loader recovers only on canvas load with no active turn or completion|PASS|PASS|一致|
|D10 production plan recovery preserves content and requires new human confirmation|PASS|PASS|一致|
|D10 successful completion persists ready and review together, never confirmed with a review|PASS|PASS|一致|
|D12 withdrawal gates reject missing authorization and non-TTY without invoking gh|PASS|PASS|一致|
|D12 withdrawal gates reject missing authorization and non-TTY without invoking gh [#2]|PASS|PASS|一致|
|D13 shell restore requires real strict signature and identity; malformed transactions do not block others|PASS|PASS|一致|
|D13 shell restore requires real strict signature and identity; malformed transactions do not block others [#2]|PASS|PASS|一致|
|D14 legacy marker allows only full ZIP on a no-manifest release|PASS|PASS|一致|
|D14 legacy marker allows only full ZIP on a no-manifest release [#2]|PASS|PASS|一致|
|D15 private GH_TOKEN reaches gh only, not the shared installer or its child environment|PASS|PASS|一致|
|D15 private GH_TOKEN reaches gh only, not the shared installer or its child environment [#2]|PASS|PASS|一致|
|D16 actual async registry scan records completion time, not its supplied entry clock|PASS|PASS|一致|
|D16 production probe replaces connected status with unknown on nil, empty or omitted server|PASS|PASS|一致|
|D17 runtime archive pins compression and refuses ad-hoc valid vendor bundles|PASS|PASS|一致|
|D17 runtime archive pins compression and refuses ad-hoc valid vendor bundles [#2]|PASS|PASS|一致|
|D17 shell version patterns agree; soft assembly failures and reused-parent symlinks fail closed|PASS|PASS|一致|
|D17 shell version patterns agree; soft assembly failures and reused-parent symlinks fail closed [#2]|PASS|PASS|一致|
|D2 attachments: local assistant, local sessions and ChatGPT take files; sessions on other devices say why and stay off|PASS|PASS|一致|
|D2 production online revalidation accepts unchanged marker and rejects withdrawn/unreachable candidates|PASS|PASS|一致|
|D2 production online revalidation accepts unchanged marker and rejects withdrawn/unreachable candidates [#2]|PASS|PASS|一致|
|D2 sub-threads are targets under their parent; every paired device lists its sessions; offline devices say so|PASS|PASS|一致|
|D2 tab overview = a two-column card grid with a neutral thumbnail (never a snapshot of a sensitive page) + 完成|PASS|PASS|一致|
|D2 到 Island 查看 opens the Island at this target's request by id, never another one|PASS|PASS|一致|
|D23 every reviewed allowance is inventoried and constrains every detected value; unknown values fail closed|PASS|PASS|一致|
|D23 key-header allowance preserves exact indentation in all regex alternatives|PASS|PASS|一致|
|D23 outer anchors constrain every policy alternative, not only first and last|PASS|PASS|一致|
|D23 reviewed inventory detects deletion, addition and same-count widening|PASS|PASS|一致|
|D3 ChatBubble carries the thread its message belongs to|PASS|PASS|一致|
|D3 allow writes the message thread, not the one Coder has selected|PASS|PASS|一致|
|D3 both transcripts pass the thread they are drawing|PASS|PASS|一致|
|D3 production URLSession delegate strips Authorization over two-host 302 chain|PASS|PASS|一致|
|D3 production URLSession delegate strips Authorization over two-host 302 chain [#2]|PASS|PASS|一致|
|D3 production code-visibility gate rejects hidden, missing and expired pairing codes|PASS|PASS|一致|
|D3 the pairing card floats on the page (the page is not squeezed); cancel top-right; big monospaced code only while its page is on screen|PASS|PASS|一致|
|D4 peer only pulls repository-scoped cached archives; corrupt downloads are cleaned|PASS|PASS|一致|
|D4 peer only pulls repository-scoped cached archives; corrupt downloads are cleaned [#2]|PASS|PASS|一致|
|D4 ［連線］ confirm = bottom sheet (取消｜連上 ChatGPT｜連線, one cancel only); 「輪到你勾選」 is a floating card (取消／繼續)|PASS|PASS|一致|
|D5 capture is blocked only while an authorisation page or the pairing code is on screen; every other protection unchanged|PASS|PASS|一致|
|D5 docs and bundled rules agree after path redaction; skill root is portable|PASS|PASS|一致|
|D5 production refresh accepts only an exact marker; legacy journals remain untrusted|PASS|PASS|一致|
|D5 real preset honors readOnly, bot override, user fallback, legacy and disclosed Grok equivalence|PASS|PASS|一致|
|D6 SIGKILL after atomic mkdir and owner write leaves a reclaimable dead lock|PASS|PASS|一致|
|D6 SIGKILL after atomic mkdir and owner write leaves a reclaimable dead lock [#2]|PASS|PASS|一致|
|D6 concurrent stale guard claimants admit exactly one updater|PASS|PASS|一致|
|D6 concurrent stale guard claimants admit exactly one updater [#2]|PASS|PASS|一致|
|D6 owner publication interruption and orphan guard takeover are recoverable; PID reuse is not live|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|D6 owner publication interruption and orphan guard takeover are recoverable; PID reuse is not live [#2]|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|D7 failed pre-transaction stage is archived; age sweep excludes transaction stages|PASS|PASS|一致|
|D7 failed pre-transaction stage is archived; age sweep excludes transaction stages [#2]|PASS|PASS|一致|
|D8 build input mode is read-only and missing iPad source is rejected before output|PASS|PASS|一致|
|D9/D11/D18 wiring and private skill export boundaries|PASS|PASS|一致|
|DM Coder sessions include the primary (and every paired device) sessions with the device name, sent through that device|PASS|PASS|一致|
|DM avatars: TATWO assistant uses the user logo, ChatGPT uses the OpenAI icon, letters stay as fallback|PASS|PASS|一致|
|DM avatars: logo on a white circle, ChatGPT black lines on white, the strip keeps only these two|PASS|PASS|一致|
|DM box and button use the App glass; no custom beige, black shadow or bubble colors|PASS|PASS|一致|
|DM composer is the compact TATWO composer; hidden while the direct-key page is open|PASS|PASS|一致|
|DM messages: Markdown like Coder, attachment paths never shown|PASS|PASS|一致|
|DM messages: user bubble, Markdown replies, error card, system note, typing dots (W184 C: phone rows, no avatar)|PASS|PASS|一致|
|DM still consumes Space shared catalog publisher; refresh does not force a tool|PASS|PASS|一致|
|DM strip: bigger icons for the two avatars; a stale session target falls back to the assistant|PASS|PASS|一致|
|DM-01: Esc belongs to the key window; composing never cancels an Island approval|PASS|PASS|一致|
|DM-02 direct native events, fresh one-shot card and proposal authorization, AX refusal|PASS|PASS|一致|
|DM-02 irreversible MAIN to SUB move refuses|PASS|PASS|一致|
|DM-02: collapse arrows never register globally; foreground routing and default direct G remain|PASS|PASS|一致|
|DM-02: settings card can turn off each direct key and explains other-app scope|PASS|PASS|一致|
|DM-03 TR-01 preview does not enroll; formal leave and approval entry|PASS|PASS|一致|
|DM-03: DM ChatGPT new-chat shortcut cannot open the main Coder window|PASS|PASS|一致|
|DM-04 labels include group and names deduplicate fleet-wide|PASS|PASS|一致|
|DM-04 local consent ceiling clips every controller until a physical approval|PASS|PASS|一致|
|DM-04: external composer replacements discard stale undo without clearing another field history|PASS|PASS|一致|
|DM-05: pointer down and drag invalidate a bare modifier chord in local and global monitors|PASS|PASS|一致|
|DM-06 inherited effective gains and identity warnings; no move promotion|PASS|PASS|一致|
|DM-06 layers: main input and popup Escape run before the window-close protection|PASS|PASS|一致|
|DM-06: closing docked, floating or tent DM protects the next main Escape and held repeats|PASS|PASS|一致|
|DM-07 MCP devices keep only selection/display fields even with an older full-record App|PASS|PASS|一致|
|DM-07 engine list and status use one allowlisted projection; protocol keeps records|PASS|PASS|一致|
|DM-07: mixed clipboard text wins in Coder and both DM columns; image-only and explicit image still attach|PASS|PASS|一致|
|DM-08 visible primary is a display-only wire type and staff view has no address|PASS|PASS|一致|
|DM-08: key capture cancels the chord in either monitor order and keeps errors visible|PASS|PASS|一致|
|DM-09 assistant slash commands are rejected before invoking the engine|PASS|PASS|一致|
|DM-09 snapshot holds secret suppression and refuses protected visible windows|PASS|PASS|一致|
|DM-10 / Sol D1: lock and classification flags do not change held-modifier gestures, including Duo|PASS|PASS|一致|
|DM-11: menu construction reads permission afresh and settings expose status and the settings button|PASS|PASS|一致|
|DM-11: visible permission UI updates grants and revocations without activating TATWO|PASS|PASS|一致|
|DM: native card over the DM (not a chat message); composer removed; code marks the sensitive gate and blocks screen capture|PASS|PASS|一致|
|DM: offline device sessions listed grey, read-only with 在這台接著聊 (same function), Coder untouched|PASS|PASS|一致|
|DevicesCard rows use signed-list membership for staff and non-staff devices|PASS|PASS|一致|
|Dia address chrome is left aligned with separate navigation controls, not a centered pill|PASS|PASS|一致|
|Dots reuses the isolated Pod and restricts return navigation to ChatGPT HTTPS|PASS|PASS|一致|
|Esc 那顆看不見的按鈕還在（浮層拿不到焦點，只有鍵盤捷徑收得到）|PASS|PASS|一致|
|F1 canvas and composer always expose mode exit|PASS|PASS|一致|
|F11 baseline and repaired production discussion creation produce different liveness|PASS|PASS|一致|
|F12 uncertain PR offers GitHub inspection and human-confirmed retry|PASS|PASS|一致|
|F2 recovery identity includes device and thread; delivery snapshot is bound to request token|PASS|PASS|一致|
|F2-10 only proven missing mappings reroute; temporary failures cannot fork a conversation|PASS|PASS|一致|
|F2-11 send automatically refreshes stale catalog once before validating or dispatching model|PASS|PASS|一致|
|F2-12 private skillet section suppresses every body entry until a public heading|PASS|PASS|一致|
|F2-13 TAP map lives in TATWO storage outside user git; no user ignore-file edits|PASS|PASS|一致|
|F2-7 real TAP stop may close without terminal event; runner must complete cancellation|PASS|PASS|一致|
|F2-8 TAP attachment admission uses secure Space reader, per-file deadline and aggregate limit|PASS|PASS|一致|
|F2-9 collaboration context is masked before truncation and visible to the user|PASS|PASS|一致|
|F3/send-03 completed canvases do not block running local commands or hide Stop|PASS|PASS|一致|
|F4 direct-key page: a 換形態 row with the current key, 更改 (same recorder), 回到預設; the menu shows the current key|PASS|PASS|一致|
|F4 form key: stored as one key name, default Tab, bad or reserved values fall back, same rules both ways|PASS|PASS|一致|
|F4 hotkeys: the form key registers only while the box shows; changing it probes, saves and re-registers; reset goes back to Tab|PASS|PASS|一致|
|F5 the desktop bubble never shows while the floating box is open; the box grows from it and shrinks back into it|PASS|PASS|一致|
|F5 the shell: same spring as the form change, corner 22 → 52, content late, no picture of the box, reduce motion fades|PASS|PASS|一致|
|F9 PR scope is explicit and another project cannot trigger a contribution checkout|PASS|PASS|一致|
|G1b drag = the system window drag (released → saved), two corners scale in proportion (the dragged corner follows, the opposite one stays), the only range limit is 44pt of the top bar; bubble mode remembered apart|PASS|PASS|一致|
|G3 file promises: only regular files directly inside this drop's folder, opened without following links, size-capped|PASS|PASS|一致|
|G3 identifiers: the DM ones stay; the new buttons get tatwo.dm.<name>|PASS|PASS|一致|
|G3 round 3: drops onto the conversation and Finder files use the same safe reader; big photos keep being accepted|PASS|PASS|一致|
|G3 round 3: voice follows the Space screen too; the DM says who holds voice; queued text is never lost|PASS|PASS|一致|
|G3 self-test in w184chat: rules, fake-Pod actions, drawn states and PNG evidence|PASS|PASS|一致|
|G3 shared, not copied: the DM ChatGPT composer and ChatGPT Space use the same components|PASS|PASS|一致|
|G3 the DM composer dispatches ChatGPT into the same glass capsule; other targets keep their composer|PASS|PASS|一致|
|G3 the tool card, model and level, and files really reach ChatGPT the way ChatGPT Space sends them|PASS|PASS|一致|
|G3 tokens: the DM set is built from DMPhone only (17/15/13/11, 36 circles, 32 chips, glass); ChatGPT Space keeps its numbers|PASS|PASS|一致|
|G3 voice owner lives in ChatGPTTap: claimed before the start is sent, one side at a time, stop confirmed or the voice page is closed|PASS|PASS|一致|
|G3 voice: ChatGPT voice mode in the web position (the DM has no dictation since G3b 追加); voice ends on Esc and when ChatGPT goes off screen|PASS|PASS|一致|
|G3b composer and ＋ card like the ChatGPT iPhone app; 「/」 commands; suggestions when empty|PASS|PASS|一致|
|G3b messages fade at the top and bottom edges (every target); ChatGPT bubbles and 「思考」 like the app|PASS|PASS|一致|
|G3b 第二輪: ChatGPT-only shortcuts, review fixes 1–8 and the lead's three PNG notes|PASS|PASS|一致|
|G3b／G3c drawer: the 22pt left edge slides it out over a still main screen (no ≡, no handle drawn); ChatGPT Space's list, DM actions|PASS|PASS|一致|
|G3b／G3c top bar: the page circle stays top-left; only 臨時聊天 top right while the ChatGPT column is on the phone (no ≡, model name or new chat)|PASS|PASS|一致|
|G3c review \#1: a temporary send is never let through unless the body actually sent carries history_and_training_disabled|PASS|PASS|一致|
|G3c review \#2: without ≡ the keyboard still reaches the list (⌘⇧S, ChatGPT's toggle-sidebar key), focus goes in and comes back; ⌘⇧O new chat|PASS|PASS|一致|
|G3c review \#3: while the drawer covers the input, the input takes no keys and Return sends nothing; composing is never cut|PASS|PASS|一致|
|G3c review \#5: the top-bar button tests really click (both columns) and a transparent-mask counterexample proves they can fail|PASS|PASS|一致|
|G3c 臨時聊天 really reaches ChatGPT as a temporary chat (every message flagged, never listed); on/off from the top right; no voice inside|PASS|PASS|一致|
|GATE-01 REV-03 roster transport is system channel|PASS|PASS|一致|
|GATE-02 TR-02 unidentified SSH cannot inherit owner authority|PASS|PASS|一致|
|GATE-03 standalone installation persists upgrade digest|PASS|PASS|一致|
|GATE-04 DM-01 five permissions cannot rewrite assistant or Hands configuration|PASS|PASS|一致|
|GPT-01 aged interrupted reconciliation guard permits later takeover|PASS|PASS|一致|
|GPT-01 aged ownerless mkdir interruption is recoverable|PASS|PASS|一致|
|GPT-02 PID plus start time rejects reused owner (liveness double)|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|GPT-03 / OPUS-04 production peer cache validator accepts repository-scoped writer path|PASS|PASS|一致|
|GPT-6 profile uses the native route with the official catalog reasoning default and fast speed|PASS|PASS|一致|
|GPT-6 review \#1/\#2: every frame that still draws the pairing code keeps its window uncapturable; the code shows only while its page is really presented|PASS|PASS|一致|
|Gen3 governance adapters wrap existing authority planes|PASS|PASS|一致|
|Git includes required project sources while retaining project-private exclusions|PASS|PASS|一致|
|GitHub release and all fresh checksums precede peer lookup; misses alone download|PASS|PASS|一致|
|Goal activation applies native model medium Fast settings before native goal/set|PASS|PASS|一致|
|Goal command before boot submits once; active acknowledgement does not invent a turn|PASS|PASS|一致|
|Goal pause failure remains visible while its original turn is still interrupted|PASS|PASS|一致|
|GoalRun live surfaces share the canonical Tatwo Ultrawork state root|PASS|PASS|一致|
|H4 DM size: phone tokens (17/15/13/11, 44 to press, concentric 28 − 12); the card floats above the composer; click-away passes the click on|PASS|PASS|一致|
|H4 applied to every same-style composer (Coder, DM, Bot Studio, Space setup); ChatGPT composers and the offline bar untouched|PASS|PASS|一致|
|H4 behavior unchanged: every control calls what the old chip or menu called|PASS|PASS|一致|
|H4 chip: one glass chip with the summary; every part keeps an old identifier; any part opens the card; narrow = shorter|PASS|PASS|一致|
|H4 one card = the ULTRAWORK card extended: header, S～XXL, 身份與模型, 速度, 推理強度, 記憶, footer; existing tokens only|PASS|PASS|一致|
|H4 self-test w184mode is registered with one line and covers the brief|PASS|PASS|一致|
|H4 the old gradient track is back (「這是舊版的拉條」): one glass bar filled from the left, drawn directly in the card|PASS|PASS|一致|
|H4b Space setup: the card hangs on the whole composer (the glass card), not on the toolbar; the open state is handed up as a Binding|PASS|PASS|一致|
|H4b TATWO assistant page: memory and model are one 模式選擇 chip; the card hangs on the whole composer; the rules are the DM assistant's|PASS|PASS|一致|
|ID selection redirects local/socket and remote assistant threads before changing Coder selection|PASS|PASS|一致|
|Island uses existing notice slot, keeps one meter, and expires from the last feedback event|PASS|PASS|一致|
|Island 設定頁掛在設定的 Tatwo Island 分頁，不再是預留空頁|PASS|PASS|一致|
|K1 both engines exclude credential URLs before argv reaches fake MCP subprocess|PASS|PASS|一致|
|M10 Claude max and fast are applied before sending the prompt; standard clears fast|PASS|PASS|一致|
|M10 Claude native controls are bound to the sent turn through SDK flag settings|PASS|PASS|一致|
|M10 Claude supportedModels is read from the SDK used by the selected executable|PASS|PASS|一致|
|M10 Codex model/list pagination reaches the sidecar protocol without starting a thread|PASS|PASS|一致|
|M10 actual Codex and SDK capabilities preserve new models, native effort and speed|PASS|PASS|一致|
|M10 catalog is queried from actual runtimes and transported from remote host|PASS|PASS|一致|
|M10 missing SDK control interface rejects the turn with an error|PASS|PASS|一致|
|M10 unavailable display, write failures and key tap failures have reasons and recovery on cards|PASS|PASS|一致|
|M11 display acceptance fixtures and read-only probe are fully inside DEBUG|PASS|PASS|一致|
|M12 empty projects hide the room and visible receipts use plain labels and glass|PASS|PASS|一致|
|M12 receipt summaries translate known machine statuses before display|PASS|PASS|一致|
|M13 Island uses the resolved application name while authorization keeps the bundle ID|PASS|PASS|一致|
|M14 DM assistant example matches the one press connection decision|PASS|PASS|一致|
|M15 model card hides route IDs and localizes native effort titles|PASS|PASS|一致|
|M15 selecting a sleeping model wakes it, while send admission stays separate|PASS|PASS|一致|
|M15 unavailable reasons are plain and the mode card offers an open ChatGPT action|PASS|PASS|一致|
|M16 DM uses Chinese conversation labels and one Island approval action|PASS|PASS|一致|
|M16 completion is the primary peer of disconnect and completed tabs keep themed glass|PASS|PASS|一致|
|M17 DM and settings use the same system permission name|PASS|PASS|一致|
|M17 display permission copy consistently includes the old permission name|PASS|PASS|一致|
|M18 permission checks do not repeat while DM menu and settings are absent|PASS|PASS|一致|
|M18 production setting card and menu own the permission watch lifetime|PASS|PASS|一致|
|M18 visible settings and menu share one watch, grant/revoke immediately, and stop when closed|PASS|PASS|一致|
|M2 all remote dispatch paths resolve a provider model even when callers omit it|PASS|PASS|一致|
|M2 an inaccessible parent must not disguise an existing document as absent|PASS|PASS|一致|
|M2 backup names are unique within a second and newest five sort by filename despite old mtimes|PASS|PASS|一致|
|M2 copy failure stops installation with a plain reason|PASS|PASS|一致|
|M2 corrupt copy stops installation with a plain reason|PASS|PASS|一致|
|M2 directory failure stops installation with a plain reason|PASS|PASS|一致|
|M2 no document can proceed; a document symlink is refused|PASS|PASS|一致|
|M2 public installer is byte identical and both scripts parse|PASS|PASS|一致|
|M2/send-06/Sol M2: every Claude entry forwards provider model, remote send declares engine|PASS|PASS|一致|
|M3/M10 officially downloaded native Codex reports gpt-6.1-sol|SKIP|SKIP|一致|
|M3/Sol M1: bundled Codex supports the default generation and verifies the downloaded native hash|PASS|PASS|一致|
|M3: local runtime selection verifies Developer ID against bundled Team ID and compares semantic versions|PASS|PASS|一致|
|M4/M10 SDK aliases resolve to the canonical provider model reported by the running CLI|PASS|PASS|一致|
|M5 failed completion prefers error reason over partial streamed text|PASS|PASS|一致|
|M5 failed completion retains the error reason when no text streamed|PASS|PASS|一致|
|M5 raw error details are persisted and expandable, blank failure rows are suppressed|PASS|PASS|一致|
|M5 retry errors expose nested reason without fatal red JSON|PASS|PASS|一致|
|M9 display discovery is demanded by use and follows system events without polling|PASS|PASS|一致|
|MCP advertises 50 tools, rejects invalid arguments, and returns structured JSON from its cwd without App socket|PASS|PASS|一致|
|MCP and settings describe session-level permissions, not 15-minute leases|PASS|PASS|一致|
|MCP begin cannot repair current session and attach remains exact rehydrate|PASS|PASS|一致|
|MCP cards bind only liveness, removal confirms via Island, builtins precede external MCP|PASS|PASS|一致|
|MCP exposes canonical revise as consume-only and no authorization issuer|PASS|PASS|一致|
|MCP：initialize（發 session）／tools/list／tools/call 轉給 App、ping、通知 202、批次不收、版本不對 400|PASS|PASS|一致|
|Mach-O parser keeps LC_RPATH spaces/order and excludes LC_ID_DYLIB|PASS|PASS|一致|
|N1 N2 actual managed launch: real Codex command and saved session resume after restart|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|NEW-1 production Swift launch recovery leaves a live shell owner lock alone (owner file has trailing newline)|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|NEW-1 production Swift launch recovery leaves a live shell owner lock alone (owner file has trailing newline) [#2]|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|NEW-2 competing lock is untouched without nested temporary directories|PASS|PASS|一致|
|NEW-3 compiled production reconcile verifies seals outside admission and restores under lock|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|NEW-4 permission guard precedes admission redirect; NEW-3 localized contention|PASS|PASS|一致|
|NEW-5 soft failures preserve diagnostics without fatal-install banner|PASS|PASS|一致|
|NEW-6 cleanup archives its own prepared stage and startup sweep archives recovered dead prepared transaction|PASS|PASS|一致|
|NEW-6 dead prepared stages archive immediately; live prepared stays; NEW-8 only aged retained locks archive|PASS|PASS|一致|
|NEW-6/8 archive destination failure is best-effort and preserves the original artifacts|PASS|PASS|一致|
|New UI files: glass chips only, in-card confirm rows, no system dialogs, no blue bordered buttons|PASS|PASS|一致|
|Node MCP executable selftest exposes and forwards the exact candidate artifact|PASS|PASS|一致|
|Node MCP source keeps the candidate route create-only and closed-schema|PASS|PASS|一致|
|OPUS-03 actual publisher archive differs from ditto for this ordinary local tree|PASS|PASS|一致|
|OPUS-07/08 actual Swift preset: Grok arguments coincide; bot configFile inherits user (W29b regression)|PASS|PASS|一致|
|OPUS-26 CPython ZipInfo open/writestr inherit no archive-level compression setting|PASS|PASS|一致|
|OPUS-35 actual receipt writer normalizes nonnumeric installSeconds to zero|PASS|PASS|一致|
|OS tools hands_setup_*: declared one per line, only the App and this device’s engines, never the external AI|PASS|PASS|一致|
|PAIR-01 DM-01: discovery contains no code-derived identifier or device name|PASS|PASS|一致|
|PAIR-01: client proves host before sending its public key|PASS|PASS|一致|
|PAIR-01: fake TCP host receives only a random challenge, never a public key or roster|PASS|PASS|一致|
|PAIR-04 PAIR-06: offer snapshot and approval transaction fail closed|PASS|PASS|一致|
|PAIR-07: complete TCP response is authenticated encryption|PASS|PASS|一致|
|PIN-02 config alias still rejects resolved same-algorithm conflicts|PASS|PASS|一致|
|PIN-02 config alias without literal pins falls back to OpenSSH resolution|PASS|PASS|一致|
|PIN-02 mixed algorithms survive; same algorithm different key refuses|PASS|PASS|一致|
|PR text creates discussing canvas without invoking contribution; bare command retains sheet|PASS|PASS|一致|
|PR4 兩種 chrome 共用同一份瀏覽器動作，AI 導覽先過既有政策|PASS|PASS|一致|
|PR4 聊天旁瀏覽器有自己的分頁檔與 runtime，不動獨立 Browser 的 registry|PASS|PASS|一致|
|PR4 靠邊停的瀏覽器要留下側欄與聊天寬度，窄視窗改上下排而不是擠壓|PASS|PASS|一致|
|PR4b fixture：Chat registry 不抄來源分頁，舊遷移檔備份後清空且只清一次|PASS|PASS|一致|
|PR4b rail hover is one state machine over all zones, not last-writer-wins|PASS|PASS|一致|
|PR4c 聊天旁頂列固定在網頁上方（不浮在 CEF 上），chrome 一律擁有點擊|PASS|PASS|一致|
|Pod createProject rejects server error, missing project ID or unconfirmed description without a send|PASS|PASS|一致|
|Pod createProject uses public first-party projects API then confirms display.description via upsert|PASS|PASS|一致|
|Pod project list follows cursors and exposes descriptions needed for stable ID matching|PASS|PASS|一致|
|Pod: Stop right after the request is posted waits for the page to show Stop and presses it|PASS|PASS|一致|
|Pod: a Send the page posts only after Stop is blocked, never reaching ChatGPT or the next user|PASS|PASS|一致|
|Pod: a Stop press the page does not take is repeated until the answer stops|PASS|PASS|一致|
|Pod: a Stop pressed before the page posts cannot let that late request stream into the next user|PASS|PASS|一致|
|Pod: a pressed Send the page never posts is released at once, without closing the Pod or eating the next Send|PASS|PASS|一致|
|Pod: a stopped Send the page posts after the next user already finished is still blocked|PASS|PASS|一致|
|Pod: exclusive lease (no page switch mid-chat), commands only on chatgpt.com, popup gesture protection untouched|PASS|PASS|一致|
|Pod: stopping a posted answer while the page hides Stop (server-side thinking) still releases promptly|PASS|PASS|一致|
|Pod: stopping a request that is still preparing never presses a Stop button it did not cause|PASS|PASS|一致|
|Pod: stopping an answer that is already streaming presses its Stop and releases promptly|PASS|PASS|一致|
|Pod: stopping an unknown request does not press another user’s Stop button|PASS|PASS|一致|
|Pod: stopping during disabled Send wait cannot send later after a new request starts|PASS|PASS|一致|
|Pod: stopping while opening a conversation cancels preparation before acknowledging|PASS|PASS|一致|
|Protected media: off by default, bridge only lifts the download block when the setting is on|PASS|PASS|一致|
|Protected media: settings card, 開始使用 item, and diagnostics show real state|PASS|PASS|一致|
|R10 negative runtime admission-once|PASS|PASS|一致|
|R10 negative runtime background-default|PASS|PASS|一致|
|R10 negative runtime reconcile-cache|PASS|PASS|一致|
|R10 negative runtime session-switch|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R10 negative runtime ui-app-unavailable|PASS|PASS|一致|
|R10 negative runtime ui-card-coordinator|PASS|PASS|一致|
|R10 negative runtime ui-complete|PASS|PASS|一致|
|R10 negative runtime ui-primary|PASS|PASS|一致|
|R10 negative runtime ui-stale|PASS|PASS|一致|
|R10 transfer rejects regression grow|PASS|PASS|一致|
|R10 transfer rejects regression memory-transferred|PASS|PASS|一致|
|R10 transfer rejects regression shrink|PASS|PASS|一致|
|R10 transfer rejects regression stale-proof|PASS|PASS|一致|
|R10 transfer rejects regression unhealthy|PASS|PASS|一致|
|R11 A/D: actionable entry in DM and Space, persistent menu entry, truthful hands_setup_status|PASS|PASS|一致|
|R11 B: not logged in = the same ［連線］ shows ChatGPT login in the box; once logged in it continues by itself (same scope, window closed while waiting)|PASS|PASS|一致|
|R11 E: the w183connect self-test covers defaults, one-press connect with Codex+memory tools, disconnect refusal, reconnect, login-then-continue, entries, and PNG evidence|PASS|PASS|一致|
|R11 UI: the ［連線］ card is icons + one line, one primary (連線) and one cancel; progress dots; connected card 「已連線：Codex、記憶」＋［斷線］; short fallbacks|PASS|PASS|一致|
|R11 default: one press of ［連線］ = Codex (L2 sandboxed workspaces) + memory read; old L1 configs are upgraded once, L0 kept; floors unchanged|PASS|PASS|一致|
|R11 disconnect: one button revokes everything on that host (ChatGPT is refused afterwards), only from the card; reconnect goes through the same confirm card|PASS|PASS|一致|
|R11 production entry r11-admission|PASS|PASS|一致|
|R11 production entry r11-cli|PASS|PASS|一致|
|R11 production entry r11-cwd|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R11 production entry r11-dialog|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R11 production entry r11-empty-card|PASS|PASS|一致|
|R11 production entry r11-external|PASS|PASS|一致|
|R11 production entry r11-invalid-target|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|R11 production entry r11-memory-race|PASS|PASS|一致|
|R11 production entry r11-return|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|R11 production entry r11-ssh-copy|PASS|PASS|一致|
|R11 production entry ui-progress|PASS|PASS|一致|
|R11 production entry ui-recovery-invalid|PASS|PASS|一致|
|R11 production entry ui-retired|PASS|PASS|一致|
|R11 production entry ui-signing|PASS|PASS|一致|
|R11 ruling replaces managed engine CLI with a real confined shell|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R11 transfer missing-pages|PASS|PASS|一致|
|R11 transfer signing-repair|PASS|PASS|一致|
|R11 transfer source-unhealthy|PASS|PASS|一致|
|R11 transfer target-ahead|PASS|PASS|一致|
|R11b 1 (high): a central level change caps existing grants before it takes effect; the default L2 only reaches a new, confirmed grant|PASS|PASS|一致|
|R11b 2 (high): consent is pinned to the press — logged in as A then logged out = back to the card; only a logged-out press continues after login|PASS|PASS|一致|
|R11b 3/4/5 (medium): the entry is per ChatGPT account, optimism expires, newer reports win, legacy hosts are "capability unconfirmed"|PASS|PASS|一致|
|R11b 6/7 (medium): disconnect tries every host and reports each; the real controller transports are exercised by w183build|PASS|PASS|一致|
|R11b2 1 (high): every raise (default upgrade, panel, write-through) passes the same host check; the panel shows one short line|PASS|PASS|一致|
|R11b2 2 (high): a cap that could not be saved (and the file not removed) never advances the watermark; a cross-restart pending ceiling fails closed|PASS|PASS|一致|
|R11b2 3 (medium): identity probes are bound to the Pod login generation; late results after logout are dropped|PASS|PASS|一致|
|R11b2 4 (medium): an unverifiable connected card becomes 「連線狀態未確認」 without capability claims; disconnect stays|PASS|PASS|一致|
|R11b2 5 (medium): the production revocation wiring is one builder that live and the tests share (tests swap only service/transport)|PASS|PASS|一致|
|R11c 1 (high): legacy hosts are never raised (a zero-grant report does not count); guarded hosts need a fresh report at the current revision|PASS|PASS|一致|
|R11c 2 (high): marker write failures are reported and fail closed; a restart caps at min(watermark, local); turn-off + raise is refused|PASS|PASS|一致|
|R11c 3 (medium): identities the flow publishes carry the Pod login generation; the entry only takes the current one|PASS|PASS|一致|
|R11c 4 (medium): "just connected" runs on the monotonic clock; clock jumps = unconfirmed; revocation is ordered by host state versions; a wrongly ended card recovers|PASS|PASS|一致|
|R12 .034: auto-tick verifies by DOM when CEF cannot see the box (native click at the re-measured centre, then DOM confirms ticked + Create enabled); Create re-found in the same form; the wait for Connect lasts the pairing window with a countdown; the expired page speaks plainly|PASS|PASS|一致|
|R12 .035: Create is pressed by a real CEF click (aim → sendClick → confirm) with the scripted press only as the logged fallback; every refused tick says why and which path ran; popups and main pages are logged by host+path; a waiting plugin dialog is not "not found"|PASS|PASS|一致|
|R12 .037: Continue to <name> is pressed by TATWO with a real click (name-bound); Create is scrolled/aimed at the visible strip; consent is compared over the risk block only; the built-but-unauthorised one is found by the remembered name|PASS|PASS|一致|
|R12 1: a generic task layout — begin mounts the task card on the left page, want switches to the task form (typing waits), end restores unless the user moved; the chat column is covered, never rebuilt|PASS|PASS|一致|
|R12 1: the connect task — in process + needs the web → inner landscape; card on the left page (no sheet, nothing on the web); connected or hidden → task ends; one column → the page stops above the card|PASS|PASS|一致|
|R12 2: the human-click step is pointed at, never clicked — the Pod script finds and measures the one button, CEF verifies the same spot (one enabled button), then the script draws a ring + arrow; the card says 「點一下亮起來的「連接」」 (「右邊」 in two pages); no pointer = the old line|PASS|PASS|一致|
|R12 3: the changed-text card shows the full plain text (verbatim) with a glass-chip 同意並繼續; agreeing stores only a SHA-256 and resumes with the exact print; the same version later resumes by itself (once)|PASS|PASS|一致|
|R12 4: no level choice — the ChatGPT Dev panel shows one plain line, the confirm card writes abilities (no level capsule), the status writes abilities; the central config unifies every device at L2 once and raises only through the R11 check|PASS|PASS|一致|
|R12 5: pressing Create stays remembered; missing entry only offers an explicit, scoped, one-run rebuild|PASS|PASS|一致|
|R12 CARDS-N1 denies git directory creation and rename|PASS|PASS|一致|
|R12 CARDS-N1 denies write .git/config|PASS|PASS|一致|
|R12 CARDS-N1 denies write .git/hooks/pre-commit|PASS|PASS|一致|
|R12 CARDS-N1 denies write .git/nested/config|PASS|PASS|一致|
|R12 CARDS-N2 background cannot connect fake SSH agent|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 CARDS-N2 engine cannot connect fake SSH agent|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 CARDS-N2 removes inherited SSH_AUTH_SOCK|PASS|PASS|一致|
|R12 CARDS-N2 terminal cannot connect fake SSH agent|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 ROSTER-02 entrance|PASS|PASS|一致|
|R12 ROSTER-02 legacy|PASS|PASS|一致|
|R12 ROSTER-02 save-failure|PASS|PASS|一致|
|R12 ROSTER-03 blank names are refused by begin and direct confirmation before RPC|PASS|PASS|一致|
|R12 ROSTER-03 promoted primary UI state pending|FAIL|PASS|環境競用；序列重跑兩版 PASS|
|R12 ROSTER-03 promoted primary UI state readback|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 connect log: release builds write one line per step (attempt code, step, result) to connect-log.txt (0600, rotated); mismatches add a page-structure snapshot (DOM text, not a screenshot); secrets are scrubbed; hands_setup_status carries the last 200 lines|PASS|PASS|一致|
|R12 production r12-admission|PASS|PASS|一致|
|R12 production r12-cli-error|PASS|PASS|一致|
|R12 production r12-cwd|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 production r12-dialog-app|FAIL|PASS|環境競用；序列重跑兩版 PASS|
|R12 production r12-dialog-offline|FAIL|PASS|環境競用；序列重跑兩版 PASS|
|R12 production r12-dialog-rejected|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|R12 production r12-errors|PASS|PASS|一致|
|R12 production r12-git|PASS|PASS|一致|
|R12 production r12-ui-card|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|R12 production r12-ui-field|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R12 production r12-ui-retired|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|R12 production r12-ui-status|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R13 CARDS-01 real tmux removes inherited agent variables|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R13 CARDS-05 reclaim over one MB returns within timeout while the main thread responds|PASS|PASS|一致|
|R13 ROSTER-01 source deletion and last-second todo survive source switch|PASS|PASS|一致|
|R13 ROSTER-02 recovery names the probed old primary and ordinary sync has no new primary|PASS|PASS|一致|
|R13 SEQ-04 the second button names the frozen originals|PASS|PASS|一致|
|R13 production r13-audit|PASS|PASS|一致|
|R13 production r13-managed-git|PASS|PASS|一致|
|R13 production r13-refusal|PASS|PASS|一致|
|R13 production r13-summary|PASS|PASS|一致|
|R14 CARDS-03 DISPATCHTEST waits for its isolated asynchronous work|PASS|PASS|一致|
|R14 CARDS-03 RECLAIMTEST waits for its isolated asynchronous work|PASS|PASS|一致|
|R14 CARDS-03 REMOTETEST waits for its isolated asynchronous work|PASS|PASS|一致|
|R14 ROSTER-01 / SEQ-03 r14-dispatch-applied|PASS|PASS|一致|
|R14 ROSTER-01 / SEQ-03 r14-dispatch-readonly|PASS|PASS|一致|
|R14 ROSTER-01 w78 named selftest uses an explicit owned fixture|PASS|PASS|一致|
|R14 ROSTER-03 ordinary primary wake cannot fan out notifications|PASS|PASS|一致|
|R14 ROSTER-03 wake fixture replaces only transport and keeps production alignment|PASS|PASS|一致|
|R14 SEQ-01 new primary start follows epoch readback, with a visible pending reason|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R14 SEQ-02 r14-second-ui completed second step is inert|PASS|PASS|一致|
|R14 SEQ-02 r14-second-update completed second step is inert|PASS|PASS|一致|
|R2-DM-03 repeated consent never steals assistant focus|PASS|PASS|一致|
|R2-GATE-01 disconnected staff retains signed roster channel|PASS|PASS|一致|
|R2-GATE-02 narrowing warning identifies device|PASS|PASS|一致|
|R2-GATE-05 reported gate identity never substitutes signed handshake|PASS|PASS|一致|
|R2-GATE-06 close verified transports before cleanup writes|PASS|PASS|一致|
|R2-REV-08 pending revocation and repin show named device status|PASS|PASS|一致|
|R3 runtime assistant: actual production checkpoint|PASS|PASS|一致|
|R3 runtime gate: actual production checkpoint|PASS|PASS|一致|
|R3 runtime gatefailure: actual production checkpoint|PASS|PASS|一致|
|R3 runtime narrow: actual production checkpoint|PASS|PASS|一致|
|R3 runtime pairing: actual production checkpoint|PASS|PASS|一致|
|R3 runtime repair: actual production checkpoint|PASS|PASS|一致|
|R3 runtime roster: actual production checkpoint|PASS|PASS|一致|
|R3 runtime warnings: actual production checkpoint|PASS|PASS|一致|
|R3-CUT-01 revocation sweep has own revision budget|PASS|PASS|一致|
|R3-DM-01 managed assistant stays local without primary fallback|PASS|PASS|一致|
|R3-DM-02 cached peer update offer cannot bypass managed isolation|PASS|PASS|一致|
|R3-DM-02 colleagues are display only and never polled|PASS|PASS|一致|
|R3-DM-02 direct status probe also refuses managed peers|PASS|PASS|一致|
|R3-DM-03 SSH job lookups never use selected conversation|PASS|PASS|一致|
|R3-DM-03 controller threads have creator and no memory bypass|PASS|PASS|一致|
|R3-DM-03 dispatch children inherit verified creator|PASS|PASS|一致|
|R3-DM-05 migrate old staff grants on load|PASS|PASS|一致|
|R3-GATE-01 unknown SSH uses verified device handshake|PASS|PASS|一致|
|R3-GATE-02 dispatcher also signs interactive restricted requests|PASS|PASS|一致|
|R3-GATE-03 revoked full owner cleanup selects its retained actual row|PASS|PASS|一致|
|R3-GATE-05 gate publish failure still converges authorization|PASS|PASS|一致|
|R3-GATE-05 missing unreferenced gate can be reinstalled|PASS|PASS|一致|
|R3-PAIR-01 preview validates and refuses legacy write|PASS|PASS|一致|
|R3-PAIR-02 restoration cleared and physically confirmed|PASS|PASS|一致|
|R3-PAIR-06 secondary menu never invites sandbox|PASS|PASS|一致|
|R3-PAIR-06 secondary sandbox fails before invitation|PASS|PASS|一致|
|R3-PAIR-07 encrypted reply mandatory|PASS|PASS|一致|
|R3-PIN-01 CA marker is not literal pin conflict|PASS|PASS|一致|
|R3-REV-01 unrelated authenticated sessions do not produce stale warnings|PASS|PASS|一致|
|R3-REV-01 unresolved connection warning has a physical confirmation action|PASS|PASS|一致|
|R3-ROSTER-01 empty controller and independent deliveries|PASS|PASS|一致|
|R3-ROSTER-02 MAIN transport survives no arrow|PASS|PASS|一致|
|R3-XFER-01 absence needs actual SSH endpoint diagnostics, not local socket failure|PASS|PASS|一致|
|R3-XFER-01 any reachable endpoint prevents an offline skip|PASS|PASS|一致|
|R3-XFER-01 only unreachable participants skip after commit|PASS|PASS|一致|
|R3-XFER-02 old graph normalized consistently when staging|PASS|PASS|一致|
|R3b Chinese step status on both devices|PASS|PASS|一致|
|R3b after authorization: both screens show the account and domain; cancel-and-reauthorize clears only this login and stops first|PASS|PASS|一致|
|R3b login URL: only on the device-signed channel while waiting; never in hands_setup_status, step messages or files|PASS|PASS|一致|
|R3b review swiftc: sensitive login tab through the real queue, lifecycle and registry never reaches disk|PASS|PASS|一致|
|R3b review: authorization is a confirmation gate bound to this round (no tunnel, DNS or start before the user confirms)|PASS|PASS|一致|
|R3b review: switching off survives a failed settings write (in-memory forced off, grants revoked first)|PASS|PASS|一致|
|R3b review: the login page is a memory-only browser tab (not in tabs.json, recently closed, archives or history) and closes when the flow ends|PASS|PASS|一致|
|R3b secondary switch: device-signed start/continue/cancel/turn_off/reauthorize run the host's standard flow; host switch follows|PASS|PASS|一致|
|R4 runtime broad-scope: actual production checkpoint|PASS|PASS|一致|
|R4 runtime broad: actual production checkpoint|PASS|PASS|一致|
|R4 runtime cards: actual production checkpoint|PASS|PASS|一致|
|R4 runtime concurrent: actual production checkpoint|PASS|PASS|一致|
|R4 runtime cut: actual production checkpoint|PASS|PASS|一致|
|R4 runtime delivery-warning: actual production checkpoint|PASS|PASS|一致|
|R4 runtime diagnostics: actual production checkpoint|PASS|PASS|一致|
|R4 runtime engine: actual production checkpoint|PASS|PASS|一致|
|R4 runtime feedback: actual production checkpoint|PASS|PASS|一致|
|R4 runtime frame: actual production checkpoint|PASS|PASS|一致|
|R4 runtime gate-status: actual production checkpoint|PASS|PASS|一致|
|R4 runtime initial-window: actual production checkpoint|PASS|PASS|一致|
|R4 runtime memory: actual production checkpoint|PASS|PASS|一致|
|R4 runtime pairing: actual production checkpoint|PASS|PASS|一致|
|R4 runtime projection-cache: actual production checkpoint|PASS|PASS|一致|
|R4 runtime read-only: actual production checkpoint|PASS|PASS|一致|
|R4 runtime replay: actual production checkpoint|PASS|PASS|一致|
|R4 runtime roster: actual production checkpoint|PASS|PASS|一致|
|R4 runtime secondary: actual production checkpoint|PASS|PASS|一致|
|R4 runtime sweep: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-controller-epoch: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-controller-window: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-managed-gate: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-managed-none: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-none: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-oneway: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-revoked: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-skipped-pending: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-skipped-return: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-skipped-two: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-source-lock: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-source-recovery: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-target-none: actual production checkpoint|PASS|PASS|一致|
|R4 runtime transfer-target-offline: actual production checkpoint|PASS|PASS|一致|
|R4-DM-02 managed leave action opens the card with physical leave action|PASS|PASS|一致|
|R5 ROSTER-N4 offline disconnect expiry is visible on consent card|PASS|PASS|一致|
|R5 runtime ack-version: actual production checkpoint|PASS|PASS|一致|
|R5 runtime bundle-auth: actual production checkpoint|PASS|PASS|一致|
|R5 runtime clock: actual production checkpoint|PASS|PASS|一致|
|R5 runtime gate-size: actual production checkpoint|PASS|PASS|一致|
|R5 runtime incremental: actual production checkpoint|PASS|PASS|一致|
|R5 runtime legacy-pin: actual production checkpoint|PASS|PASS|一致|
|R5 runtime legacy-self: actual production checkpoint|PASS|PASS|一致|
|R5 runtime local-error: actual production checkpoint|PASS|PASS|一致|
|R5 runtime memory-pin: actual production checkpoint|PASS|PASS|一致|
|R5 runtime migration: actual production checkpoint|PASS|PASS|一致|
|R5 runtime native: actual production checkpoint|PASS|PASS|一致|
|R5 runtime push-version: actual production checkpoint|PASS|PASS|一致|
|R5 runtime retries: actual production checkpoint|PASS|PASS|一致|
|R5 runtime secondary-invite: actual production checkpoint|PASS|PASS|一致|
|R5 runtime secondary-warning: actual production checkpoint|PASS|PASS|一致|
|R5 runtime transfer-former-retries: actual production checkpoint|PASS|PASS|一致|
|R5 runtime transfer-lock-begin: actual production checkpoint|PASS|PASS|一致|
|R5 runtime transfer-lock-update: actual production checkpoint|PASS|PASS|一致|
|R5 runtime transfer-recovery-convergence: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime clock-gate: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime disconnect-targets: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime legacy-ack: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime legacy-names: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime legacy-prepared: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime memory-endpoints: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime memory-errors: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime native-memory: actual production checkpoint|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R6 negative runtime restore-host-key: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime restore-old-key: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime revocation-retry: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime secondary-forward: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime transfer-ack-churn: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime transfer-coordinator-recovered: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime transfer-new-primary-skip: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime transfer-return-app-closed: actual production checkpoint|PASS|PASS|一致|
|R6 negative runtime transfer-return-online: actual production checkpoint|PASS|PASS|一致|
|R7 CARDS-03 real Codex command runs without nested sandbox or approval and denies every private path|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R7 CARDS-04 approved child cannot borrow an unsandboxed Unix server or LaunchServices|PASS|PASS|一致|
|R7 CARDS-04 copied renamed resigned osascript cannot send to the owned synthetic receiver|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R7 negative runtime dm-actions: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime memory-endpoints: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime memory-errors: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime memory-fetch: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime native-paths: actual production checkpoint|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R7 negative runtime projection-errors: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime secondary-leave: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-fork: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-retired: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-return-denied: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-return-exhausted: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-return-next: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-return-signature: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-skip-online: actual production checkpoint|PASS|PASS|一致|
|R7 negative runtime transfer-stale-evidence: actual production checkpoint|PASS|PASS|一致|
|R7 prior CARDS-01 invitation does not promise unavailable conversation or terminal results|PASS|PASS|一致|
|R8 CARDS-01 App socket directories remain denied|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 CARDS-01 DNS and TLS survive the same inherited profile|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 CARDS-02 stderr stdout descriptor PTY and module cache work|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 CARDS-04 private read denied .bash_history|PASS|PASS|一致|
|R8 CARDS-04 private read denied .bash_sessions/private|PASS|PASS|一致|
|R8 CARDS-04 private read denied .zsh_history|PASS|PASS|一致|
|R8 CARDS-04 private read denied .zsh_sessions/private|PASS|PASS|一致|
|R8 CARDS-04 private read denied Library/Application Support/TATWO OS/Browser/private|PASS|PASS|一致|
|R8 CARDS-04 private read denied Library/Caches/tatwo2/Cache/private|PASS|PASS|一致|
|R8 R7-CARDS-04 claude write boundary|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 R7-CARDS-04 cli write boundary|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 R7-CARDS-04 codex write boundary|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 R7-CARDS-04 grok write boundary|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 R7-CARDS-04 run_background write boundary|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 R7-CARDS-05 MCP advertises stop tracking through confirmed proposal|PASS|PASS|一致|
|R8 negative runtime cli-history|PASS|PASS|一致|
|R8 negative runtime entry-background|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 negative runtime entry-claude|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 negative runtime entry-cli|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 negative runtime entry-grok|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 negative runtime entry-openai|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|R8 negative runtime memory-errors|PASS|PASS|一致|
|R8 negative runtime memory-full-fetch|PASS|PASS|一致|
|R8 negative runtime memory-push|PASS|PASS|一致|
|R8 negative runtime projection-enum|PASS|PASS|一致|
|R8 negative runtime projection-schema|PASS|PASS|一致|
|R8 negative runtime projection-storage|PASS|PASS|一致|
|R8 negative runtime revocation-pending|PASS|PASS|一致|
|R8 negative runtime row-warnings|PASS|PASS|一致|
|R8 negative runtime stop-tracking|PASS|PASS|一致|
|R8 negative runtime transfer-recovery|PASS|PASS|一致|
|R9 negative runtime brain-empty|PASS|PASS|一致|
|R9 negative runtime brain-mismatch|PASS|PASS|一致|
|R9 negative runtime brain-missing|PASS|PASS|一致|
|R9 negative runtime brain-online|PASS|PASS|一致|
|R9 negative runtime brain-source|PASS|PASS|一致|
|R9 negative runtime memory-errors|PASS|PASS|一致|
|R9 negative runtime memory-launch|PASS|PASS|一致|
|R9 negative runtime memory-restricted-fetch|PASS|PASS|一致|
|R9 negative runtime revocation-resweep|PASS|PASS|一致|
|R9 negative runtime ui-complete|PASS|PASS|一致|
|R9 negative runtime ui-initial|PASS|PASS|一致|
|R9 negative runtime ui-observer|PASS|PASS|一致|
|REG-03 DM-05: every non MAIN-owner arrow has a forced SSH gate|PASS|PASS|一致|
|REG-03 DM-05: installed gate allows only its local socket and live controller methods|PASS|PASS|一致|
|REG-05 every production caller reaches dual-source validation before launching SSH/SCP/rsync|PASS|PASS|一致|
|REG-05 general remote calls use gate for restricted peers and compose both pins|PASS|PASS|一致|
|REG-05 pin conflict repair retains registry and clears marker|PASS|PASS|一致|
|REG-05 rsync -e parser preserves both pin paths with spaces using only a fake SSH process|PASS|PASS|一致|
|REG-05 shared script/GBrain policy: either source, duplicate, conflict, hashed host, revoked key, unknown host|PASS|PASS|一致|
|REG-05 shell wrapper refuses before executing a fake transport and preserves argv with spaces|PASS|PASS|一致|
|REG-05: pin failure cannot prevent revocation; dedicated host store|PASS|PASS|一致|
|REV-01 revoked projections cannot poison owner apply|PASS|PASS|一致|
|REV-05 restored identity requires explicit invitation scope|PASS|PASS|一致|
|ROSTER-02 TR-01 DM-03: revocation is a confirmable graph operation|PASS|PASS|一致|
|ROSTER-02 native stdio transition: anonymous-controller-row|PASS|PASS|一致|
|ROSTER-02 native stdio transition: restricted-row|PASS|PASS|一致|
|ROSTER-02 native stdio transition: unrestricted-row|PASS|PASS|一致|
|ROSTER-02 signed system messages use a channel compatible with both actual key rows|PASS|PASS|一致|
|ROSTER-08 shared visible-name policy, duplicate suffixes, card role and short fingerprint|PASS|PASS|一致|
|ROSTER-09 TR-06: revoked delivery is private and bounded|PASS|PASS|一致|
|ROSTER-N4 new proposals do not carry an old physical disconnect event|PASS|PASS|一致|
|RPC trust: memory_sync_* need a device signature, never SSH remote control or staging read-only|PASS|PASS|一致|
|RemoteDeviceSession writes the snapshot while connected and reads it back when offline (App restart included)|PASS|PASS|一致|
|Review card (v3 V6): candidate SHA, main-line advanced notice, executable files flagged, no copy-merge-command; no orange dot for hands rooms|PASS|PASS|一致|
|Rooms: per-project root, no engine, rows per call, watchdog excluded, composer and redo locked, selftest wired|PASS|PASS|一致|
|S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe|PASS|PASS|一致|
|S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe › A2 slow main-thread selection returns immediately|PASS|PASS|一致|
|S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe › S1 adhoc candidate execution and environment|PASS|PASS|一致|
|S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe › S1 other candidate execution and environment|PASS|PASS|一致|
|S1 rejected candidates execute zero times; accepted version probes receive no inherited secrets; A2 slow main-thread probe › S1 same candidate execution and environment|PASS|PASS|一致|
|S2 corruption or removal during pruning stops installation after the final comparison|PASS|PASS|一致|
|S2 mixed local-time legacy names cannot prune the current UTC backup|PASS|PASS|一致|
|S4 production goal branch captures native intent before clearing the composer|PASS|PASS|一致|
|SSH capability gate captures daemon identity before request bytes and intersects W178|PASS|PASS|一致|
|SSH wrappers fail before any command or state write when host is unset or empty|PASS|PASS|一致|
|Search keeps its centered geometry without fake installed extension icons|PASS|PASS|一致|
|Secondary device RPC: device-signed like memory_propose, whitelisted fields, never an AI tool|PASS|PASS|一致|
|Self-test w183ui is registered and never touches the real keychain or network|PASS|PASS|一致|
|SelfTest covers late root creation, observation, cooldown and changed manifests|PASS|PASS|一致|
|Session mapping display cannot persist or log private titles|PASS|PASS|一致|
|Settings › Plugin lists Skillet, MCP, TAP, Pocket in that order with glass chips only|PASS|PASS|一致|
|Skillet and Pocket sources and protected PluginsPage regions are unchanged|PASS|PASS|一致|
|Space gets a ChatGPT tab wired like Browser, with its own sidebar and no Coder composer|PASS|PASS|一致|
|Space notices: shared SpaceNotice via Island, per-Space switch, ChatGPT posts when you are not on that conversation|PASS|PASS|一致|
|Space ready, refresh, plus-menu and plugin-page events use the single catalog loader|PASS|PASS|一致|
|Standard setup flow: eight steps, only authorize and pairing need the user, resumable state with no secrets|PASS|PASS|一致|
|Stop after terminal completion still pauses an active native Goal|PASS|PASS|一致|
|Stop during settings cancels old Goal before any activation and preserves explicit later request|PASS|PASS|一致|
|Swift queue has scoped cancellation, stop acknowledgement gate, and idle usage accounting|PASS|PASS|一致|
|Swift self-test exercises real display building and fallback scenarios|PASS|PASS|一致|
|Swift：Apple 裝置端翻譯、外語才出現、可還原、記住網站；設計檔只多一行|PASS|PASS|一致|
|T1 網段：IPv4／IPv6／mapped 比對正確，太寬或亂寫的網段不收|PASS|PASS|一致|
|T10 日誌：關口只印固定欄位（logEntry），送什麼奇怪的值都不會進去|PASS|PASS|一致|
|T10 錯誤不洩漏內部資訊；canary 不出現在不該出現的回應|PASS|PASS|一致|
|T10 關口不寫檔：日誌走 stdout 事件、只有固定欄位、掃不到任何 canary；socket 0600、socket 資料夾裡只有 socket|PASS|PASS|一致|
|T10／T11 兄弟行程收尾：App 被強制結束（SIGKILL）→ 關口（stdin EOF）與 cloudflared（看門程式）兩組都自己收、token 檔刪掉；cloudflared 停了看門程式也收|PASS|PASS|一致|
|T11 大請求被拒；每個 grant、全關口 MCP、metadata、/token（全域與每 client）、註冊都有上限|PASS|PASS|一致|
|T11 長的 tools/call 用 SSE：先回標頭、定時保活、最後一個 event 是結果（Cloudflare 約 100 秒沒位元組就斷）|PASS|PASS|一致|
|T12 rewrite: many devices reachable, none can manage others; AI tools cannot change the build config (counter-examples)|PASS|PASS|一致|
|T14 程式與測試不寫死網域、主機名：用公開掃描器實掃（私人清單在就一起比「類別 \| 正規式」，不在就跑通用規則）|PASS|PASS|一致|
|T2 錯碼用完就作廢（App 說 pairing_expired）|PASS|PASS|一致|
|T2/T3/T15 pairing window, confirmation card, grants and tokens (v2 §3–§5, v3 V9, V13, V15, V17)|PASS|PASS|一致|
|T7 identity: .externalAI is not bound to a thread, not trusted, not inherited, and only reaches the three hands methods|PASS|PASS|一致|
|T8／T13 cloudflared Seatbelt 實跑：讀不到家目錄（含 .cloudflared）與手腳資料夾、除了 cf-home 哪裡都寫不了（工具鏈、/tmp）、只連得到關口的 socket、本機 TCP 服務一律連不到、內網與本機網卡的 443 連不到、只開 Cloudflare 用的埠、開不了其他程式|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|T8／v3 V8 關口 Seatbelt 實跑：關口照常服務、叫得到 os.sock；讀不到 App 設定與 OAuth 狀態、通道 token、cf.yml、~/.ssh 替身；除了自己的 socket 哪裡都寫不了；連不到其他 socket、不能對外連線、不能開程式|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|TAP chip retains full identity and exposes only native TAP effort IDs|PASS|PASS|一致|
|TAP code never logs or writes conversation content or tokens|PASS|PASS|一致|
|TAP never compares composer text byte for byte; every check ignores rewritten whitespace|PASS|PASS|一致|
|TAP requests never pass an item id as "id" (the request id would overwrite it)|PASS|PASS|一致|
|TAP route is a separate model brand after OpenAI, with unavailable placeholder and native TAP efforts|PASS|PASS|一致|
|TAP step: the switch flow prepares the workspace right before starting the gateway; auto-resume checks the same|PASS|PASS|一致|
|TAP › ChatGPT: one card with ChatGPT build (switch, ⓘ with the one sentence, node flow); logic behind HandsBuildModel|PASS|PASS|一致|
|TATWO composer is the Coder composer: same text view, glass card, toolbar, send/stop, status drawer|PASS|PASS|一致|
|TATWO has its own transcript/composer, selectable conversation and disabled future rows|PASS|PASS|一致|
|TATWO is a builtin with stable raw identity, first in all three tab lists|PASS|PASS|一致|
|TR-02 and REG-05 cards surface uncertain connections and pin conflict|PASS|PASS|一致|
|TR-03: rotation requires old-primary commit and bound projection|PASS|PASS|一致|
|TR-04 TR-05: pending handoff expires; offline projection is deferrable|PASS|PASS|一致|
|TR-04 every uncommitted handoff can cancel through direct physical input|PASS|PASS|一致|
|Tap: a send the page never answers fails after a silence watchdog instead of spinning forever|PASS|PASS|一致|
|Tools: exactly the v2 §7 table (+v3 + W185 CU/skillet + W225 collaboration), levels, schemas, job limits, request_id ledger, output area|PASS|PASS|一致|
|Transcript tables keep the look the user liked (semibold header, darker header rule, light row rules)|PASS|PASS|一致|
|Transcript tables keep the look the user liked (semibold header, darker header rule, light row rules) [#2]|PASS|PASS|一致|
|UI delegates control and never embeds private configuration|PASS|PASS|一致|
|UI selftest renders all seven artifacts with fixture service, sliders, toggle and notices|PASS|PASS|一致|
|UI tokens and identifiers: fonts 17/15/13/11 from DMPhone, 44pt buttons, glass not blue, new ids tatwo.dm.tent.*|PASS|PASS|一致|
|Unicode, emoji, quotes and code-like input are data, never source|PASS|PASS|一致|
|V1/V3/V4 export: git archive of a fixed base SHA through a clean shadow gitdir, APFS clone for dependencies, nothing is installed|PASS|PASS|一致|
|V14 memory: formal memory readable minus "not for ChatGPT", inbox fields written by the App, list only your own|PASS|PASS|一致|
|V2/V7/T6/T11 sandbox: deny-default, no network, no Homebrew, protected names at any depth and case, other workspaces denied, limits, marks|PASS|PASS|一致|
|V5/V10/T16 submit: stop writers, commit inside the sandbox, build the candidate with a temporary index, never check out|PASS|PASS|一致|
|V6 review and merge: Hands backend, fixed candidate SHA, main-line advance flagged, no copy-merge command|PASS|PASS|一致|
|V9 grant owns everything; switching off, lowering the level or removing a project cancels work and locks workspaces|PASS|PASS|一致|
|W100 a: RemoteLiveEngine 的 View getter 只讀快取，link 呼叫只在背景 refresh|PASS|PASS|一致|
|W100 b: RemoteHostLink 的 SSH 入口都禁止主佇列|PASS|PASS|一致|
|W100 c: ChatPageModel 的畫面 getter 只讀 getter；寫入與連線都在背景|PASS|PASS|一致|
|W100 d: 沒有快取時對話區顯示「連線中…」|PASS|PASS|一致|
|W100 e: 主佇列進 RemoteHostLink.call 會被擋，背景佇列照常回錯誤|PASS|PASS|一致|
|W100b f: SelfTest harness 等完成回呼，診斷入口不在主執行緒打 SSH|PASS|PASS|一致|
|W105 Island 設定的每個鍵都登記在匯出偏好隔離的出廠值裡|PASS|PASS|一致|
|W106 回歸：背景讀鑰匙圈不准跳系統視窗；授權只能由使用者按鈕觸發|PASS|PASS|一致|
|W106 憑證挑選：過期的那份不可以蓋過還能用的那份|PASS|PASS|一致|
|W106 登入與聊天共用同一個 Claude Keychain namespace|PASS|PASS|一致|
|W106 讀不到額度時不再誤導成「要重新登入」|PASS|PASS|一致|
|W106 額度只從 ClaudeCredentialStore 拿憑證，不自己拼服務名|PASS|PASS|一致|
|W109: chat-side browsers are listed in the Browser Session space by project/thread and open live|PASS|PASS|一致|
|W110: the offline copy is for the screen only — no OS tool or bridge method reads another device's history|PASS|PASS|一致|
|W115d ⌘T 取消是明確收面板，不靠焦點變化推導|PASS|PASS|一致|
|W116g 完整模式子視窗：位置由 Swift 交、原生端只認實驗旗標與 defaults 裡的測試擴充路徑|PASS|PASS|一致|
|W117 Fable 額度：讀官方 limits 陣列裡單一模型的週上限（對照官方 CLI 的用量面板）|PASS|PASS|一致|
|W119 翻譯鈕是自動翻譯開關；換頁續翻；取文字逾時不會卡在轉圈|PASS|PASS|一致|
|W119b 第一批譯文寫回就收掉轉圈，不等整頁翻完|PASS|PASS|一致|
|W120 按「-」關掉正在看的書籤分頁＝回 Browser 首頁，不跳到清單第一個|PASS|PASS|一致|
|W122 拼圖鈕展開的是選單（不是對話框）：已裝的擴充可釘選、管理與商店各有去處|PASS|PASS|一致|
|W144 進階管理不像另一個視窗：沒有 Chrome 工具列、沒有標題列與紅綠燈、不能單獨拖走；換分頁就收起|PASS|PASS|一致|
|W146 擴充頁開著時工具列固定顯示；改 styleMask 後逼核心重排，隱形標題列不留空白|PASS|PASS|一致|
|W148 擴充頁頂端貼齊工具列（定位點不吃安全區域）；網址位置顯示「擴充功能」|PASS|PASS|一致|
|W152 擴充自己開的頁面改開在左列新分頁：讀網址列→交給外部連結佇列→關掉那個 Chrome 視窗；讀不到才收編|PASS|PASS|一致|
|W153 結束 App 前先關掉擴充用的 Chrome 瀏覽器並等它銷毀，CEF 才拆 profile|PASS|PASS|一致|
|W153b 使用者確認結束後、App 還在正常運轉時就關掉擴充用瀏覽器並等它銷毀，再放行結束|PASS|PASS|一致|
|W154 讀不到網址的空白新分頁視窗直接關掉；結束前的等待也把收編來的核心視窗算進去|PASS|PASS|一致|
|W160 dispatch carries the optional entry files and the primary refreshes agents.md first|PASS|PASS|一致|
|W160 production Swift: agents.md is rendered from the constitution summary|PASS|PASS|一致|
|W160 production Swift: engine link scan and link archive the original and never duplicate|PASS|PASS|一致|
|W160 settings: OS page shows engines and opens documents; separate 文件 tab is gone; onboarding asks about backup|PASS|PASS|一致|
|W162 production Swift: audit finds injections, secret-looking lines (without content) and commands|PASS|PASS|一致|
|W162 wiring: device_status carries engine state; OS page shows peers and the read-only scan|PASS|PASS|一致|
|W163 production Swift: remember parsing, dedupe, append to user.md, Claude memory import|PASS|PASS|一致|
|W163 wiring: device RPCs, os.sock user_remember, MCP tool, chat hook, approval page|PASS|PASS|一致|
|W170 production Swift: goal list only appends, guards completion, keeps one active, handles proposals|PASS|PASS|一致|
|W170 wiring: /goal for every engine, plan and plg create goals, engine tools, per-turn summary, Coder name, sidebar untouched|PASS|PASS|一致|
|W171 Space: fresh install gets one default domain; the Space page layout stays as is|PASS|PASS|一致|
|W171 Space: fresh install gets one default domain; the Space page layout stays as is [#2]|PASS|PASS|一致|
|W171 first run: safe defaults only, straight into the App|PASS|PASS|一致|
|W171 first run: safe defaults only, straight into the App [#2]|PASS|PASS|一致|
|W171 settings: 開始使用 first, pending dots; merged login hides completed setup|PASS|PASS|一致|
|W171 settings: 開始使用 first, pending dots; merged login hides completed setup [#2]|PASS|PASS|一致|
|W175 built-in Claude engine can reach Opus 5.5; roles follow constitution §4|PASS|PASS|一致|
|W175 picker lists only current models|PASS|PASS|一致|
|W175 retired IDs resolve to their replacements|PASS|PASS|一致|
|W178 os.sock: other local programs only reach status and proposal methods; a silent peer cannot block the bridge|PASS|PASS|一致|
|W178 pairing: code never crosses the network, MITM key swaps and injected ssh options are refused|PASS|PASS|一致|
|W179 Island classification and room failure wording remain identical to w179/base|PASS|PASS|一致|
|W179 goal_index and os_status always read the local engine and identify the local device|PASS|PASS|一致|
|W179 real MCP transport: valid metadata injection and fail-closed arguments, bound and unbound|PASS|PASS|一致|
|W179 real Swift bridge: isolated goal_index and os_status metadata-only acceptance|PASS|PASS|一致|
|W179 the on-device model manager uses Chromium's override delegate so its free-space check cannot spin|PASS|PASS|一致|
|W179 tool declarations, trust boundaries, read-only sources and synchronized guidance|PASS|PASS|一致|
|W180 B3 superseded backups are removed in place (no Trash) and nested symlinks are not followed|PASS|PASS|一致|
|W180 E1 chips: TATWO and DM next to the model chip, Coder only in .chat, none for ChatGPT|PASS|PASS|一致|
|W180 E1 memory page: tab opened, glass chips, in-card confirm, folder-missing text, sync status row|PASS|PASS|一致|
|W180 E1 memory tools: one tuple per line, App/engines only, persona usage, 50 tools (with E3b)|PASS|PASS|一致|
|W180 E1 memory: indexing succeeds before emission; Coder folds usage and shared surfaces retain disclosure|PASS|PASS|一致|
|W180 E1 per-turn memory: after the goal summary, before sidecar.send, after the disable guard; cache only on the main thread|PASS|PASS|一致|
|W180 E1 pure logic (swiftc): recall, strength limits, frontmatter, usage note|PASS|PASS|一致|
|W180 E1 review fixes: Bot detection, preview, fresh cache, secrets, index lines, recent, secondary devices|PASS|PASS|一致|
|W180 E1 self-test entry covers every step|PASS|PASS|一致|
|W180 E1 strength field, defaults and per-thread writes|PASS|PASS|一致|
|W180 E1 threads on the primary: the choice rides with the next sentence; old primaries still accept it|PASS|PASS|一致|
|W180 E1 writes: secret check, index via entryLine, commit through EngineMemoryLinks, forget is an archive|PASS|PASS|一致|
|W180 E1b memory sync RPCs: signed-device group only|PASS|PASS|一致|
|W180 E1b merge rules (production Swift compiled standalone)|PASS|PASS|一致|
|W180 E4 canvas actions: glass chips, confirm only on a current preview, boundary saved before any write|PASS|PASS|一致|
|W180 E4 drafting: default skill rules, tatwo-distill fence, /蒸餾 translated for the engine|PASS|PASS|一致|
|W180 E4 guidance: /蒸餾 turns a finished session into reusable material, not GBrain-only|PASS|PASS|一致|
|W180 E4 production Swift acceptance: TATWO2_SELFTEST=w180distill|PASS|PASS|一致|
|W180 E4 remote distill: paired-device channel only, SSH callers only, no command or computer rights|PASS|PASS|一致|
|W180 E4 review fixes: writes stay on the primary, off the serial bridge queue, bound to their own canvas|PASS|PASS|一致|
|W180 E4 skillet is never a destination; memory is not an output kind; reserved names|PASS|PASS|一致|
|W181 reuse assertion rejects runtime and memory checks split across returns|PASS|PASS|一致|
|W182 R5 assistant_append_offline: paired devices only|PASS|PASS|一致|
|W182 R5 edits in shared files are small, marked insertion points|PASS|PASS|一致|
|W183 R1 external AI: exact three-method allowlist, never in the existing lists|PASS|PASS|一致|
|W183 R10 card: no scope chooser (no level segments, no project layer, no "go tick first" hint); read-only summary + the consent line next to ［連線］; glass chips, native card|PASS|PASS|一致|
|W183 R10 host: no scope on the card — begin with level/project_ids is refused before anything is written; the snapshot is the central level + all projects (digest "*")|PASS|PASS|一致|
|W183 R10 pod tick: an unknown checkbox (ticked or not) → "checkbox"; no tick unless it is exactly that one box|PASS|PASS|一致|
|W183 R10 pod tick: no reliable place → no tick (hand to the user): pinch-zoomed or shifted visual viewport, box off-screen or too small, something on top of it, no viewport getters, a styled tiny box behind its label|PASS|PASS|一致|
|W183 R10 pod tick: only the one known box on the verified 09-29 English form → needs_user + tick; the script itself never ticks; the App's native click on it → armed → Create once|PASS|PASS|一致|
|W183 R10 projects: every host project stays visible to MCP; W214 removes the Dev panel list|PASS|PASS|一致|
|W183 R10 remote status reports the effective scope (central level, all projects) and the host project list; W214 hides project chips|PASS|PASS|一致|
|W183 R10 self-test covers the scope rules (all visible, central level, card refused, trading view-only, counterexamples)|PASS|PASS|一致|
|W183 R10 tick & press contract (static, next to the dynamic tests above): the Pod only measures and never presses on its own; the App ticks the one node it recorded (CEF backendNodeId, node-verified click, consent re-checked just before), binds every step of Create to one lease and one operation, and sets the provenance anchor before it sends the press|PASS|PASS|一致|
|W183 R10 第三輪 consent binding (GPT-6 3): what the auto-tick agreed to (version, ordered text, link texts and resolved sites) is re-checked right before the click (connectorConsent) and before Create is pressed; a link that now points elsewhere → hand back to the user, nothing pressed|PASS|PASS|一致|
|W183 R10 第二輪 pod consent whitelist: anything but the verified full text is "unknown" (reason stays risk_ack, no tick): Chinese UI, a keyword-free new clause, a reworded or reordered form, a link to another site|PASS|PASS|一致|
|W183 R10 第二輪 two-step press (GPT-6 1): Create / reconnect only after the App set its anchor — armed never presses; the press re-checks everything and is one-time; anything that changed in between → press_stale, nothing pressed|PASS|PASS|一致|
|W183 R12 pod Continue: the "Connect <name>" dialog with the one "Continue to <name>" is found as kind continue (name must match); a real click on it = landed; another name or two buttons = not this step|PASS|PASS|一致|
|W183 R12 pod Create only 6px on screen (.037: 405,610.7 78x36 in 524x617): aimed at the visible strip|PASS|PASS|一致|
|W183 R12 pod Create re-rendered (.034 real page: React redraws after the tick): the press re-finds the one "Create" in the same form and presses it once; a changed field is still press_stale with a snapshot of why|PASS|PASS|一致|
|W183 R12 pod DOM tick counter-examples: a second checkbox, a disabled box, a changed label or changed consent text between measuring and aiming → not aimed (the App does not click)|PASS|PASS|一致|
|W183 R12 pod DOM tick: aim re-verifies the one box in TATWO's own form (consent unchanged, label matches, visible, enabled, unticked) and measures it; after the native click it reports ticked + Create enabled; the script never ticks|PASS|PASS|一致|
|W183 R12 pod consent over the risk section only: when the risk text and the box sit in their own block, that block alone is checked (the risk-only version matches; an alert or another Name elsewhere does not matter); a changed clause shows only that block on the card|PASS|PASS|一致|
|W183 R12 pod consent: an unknown text comes back as plain text + links (text, domain) + one print; only that exact print brought back by the App makes it known (tick → Create once); a link to another site or a different print stays unknown; abort forgets it|PASS|PASS|一致|
|W183 R12 pod gesture pointer: the one Connect in the box showing our URL is scrolled into view and measured; a ring + arrow are drawn only after the App verified it (show), never clicked; alive / clear / abort|PASS|PASS|一致|
|W183 R12 pod gesture pointer: two buttons in that box, a box without our URL (and more than one dialog), a moved button or a stale mark → nothing is drawn|PASS|PASS|一致|
|W183 R12 pod gesture: after Create the whole plugin dialog waits (Create disabled, box ticked) → waiting, not "not found"|PASS|PASS|一致|
|W183 R12 pod native Create: aim checks everything and measures Create without pressing; a real click on it + confirm = pressed (native); no click = the script presses (native:false); a real click elsewhere = press_missed, never a second press|PASS|PASS|一致|
|W183 R12 pod outline: the main dialog as an element tree (tag, role, input type/name/checked, button and label text, 80 chars per text), never field values; iframes by origin only; 16 KB cap|PASS|PASS|一致|
|W183 R12 pod reconnect by name: the list cannot see the built-but-unauthorised one — the one link whose text is exactly the remembered name is opened, the full URL and OAuth are checked in its detail, then its Connect is armed/pressed; the base name never matches the "…2" one|PASS|PASS|一致|
|W183 R1: ChatGPT hands rooms are never stopped by the liveness check; other rooms still are|PASS|PASS|一致|
|W183 R1b review fixes: truncation, admission, submit lock, scan certainty, revocation persistence, redaction, disk, replay|PASS|PASS|一致|
|W183 R3 hands setup tools and secondary RPC: trust lists|PASS|PASS|一致|
|W183 R4 整合測試：取代唯一的 SKIP、走真的 os.sock／HandsService／關口、十步都在、在模擬 App 結束之前跑|PASS|PASS|一致|
|W183 R5b／R8b: Cloudflare authorization opens as a tab in the DM box Browser (phone in-app browser), not an OS Browser tab|PASS|PASS|一致|
|W183 R6a auto-resume after the host App restarts: only tunnel, gateway and existing grants; never login, offer, pairing window or retry; safety stop survives|PASS|PASS|一致|
|W183 R6a fixed subdomain os-for-chatgpt: taken name stops (no overwrite, no rename); random→fixed migration deletes only the recorded TATWO CNAME|PASS|PASS|一致|
|W183 R6a flow: switch → authorize in the DM box; pairing step → offer() (no pairing window); off / host change / cancel → cancel(reason:)|PASS|PASS|一致|
|W183 R6a secondary: resync when the host setting changes, force a fetch while there is no status, ≤10 s backoff while the page is visible, hand back|PASS|PASS|一致|
|W183 R6a self-test covers the one-switch rules and never touches the real keychain or network|PASS|PASS|一致|
|W183 R6a unused TATWO tunnels: only tatwo-hands-, no connections, not in use; confirm first; recheck before delete; same sandbox; category-only errors|PASS|PASS|一致|
|W183 R7a old DNS record: kept when the new URL cannot be confirmed, then retried automatically (no press); confirmation has a second path that avoids the system DNS cache|PASS|PASS|一致|
|W183 R7a step messages: no internal room codes; button names in messages match the screen (authorize = 重新授權, others = 重試); the one line has no step numbers|PASS|PASS|一致|
|W183 R7a/R10 AI tools cannot change the level or projects (the only writers: the signed central config mirrored by the reconciler, the settings screen, normalisation)|PASS|PASS|一致|
|W183 R8 integration review: apply pins the seen snapshot; legacy remote setup is not an apply; owner-only login URL; local unlock is incident-bound|PASS|PASS|一致|
|W183 R8 integration review: central cap enforced on every call; narrowing that cannot be saved suspends; no report is not "off"; connect round ends on dismiss|PASS|PASS|一致|
|W183 R8a flow looks like the mock: dotted canvas, curved edges (solid brand / dashed grey), node badges, keyboard and VoiceOver|PASS|PASS|一致|
|W183 R8a interface: HandsBuild.swift unchanged; HandsBuildModel is the adapter; the screen only talks to the model through intents|PASS|PASS|一致|
|W183 R8a no long explanation text on the main card (strings live in HandsBuildCopy; details only behind 「…」 and ⓘ)|PASS|PASS|一致|
|W183 R8a one card: ChatGPT build row, node flow, one panel at a time; engineering details only behind 「…」|PASS|PASS|一致|
|W183 R8a review: the build card is a sensitive surface for Computer Use; secondary can reject a pending authorization; provisional grants are not connected|PASS|PASS|一致|
|W183 R8a safety: scope and URL changes only where allowed; connect is the DM card; no AI tool reaches the build model|PASS|PASS|一致|
|W183 R8a self-test w183ui covers node states, panel switching, one vs many devices, intents and the adapter, short text|PASS|PASS|一致|
|W183 R8b: the third round icon Browser swaps the box content for a phone browser; box size and look unchanged|PASS|PASS|一致|
|W183 R8c pod connector: named TATWO（<device name>）; anything else falls back to TATWO|PASS|PASS|一致|
|W183 R8c review (Claude): polling only when needed, backoff when offline, no re-verify, no republish, no disk reads in view getters|PASS|PASS|一致|
|W183 R9 App side: step codes become sentences (no more 「（plus）」), risk_ack / untrusted card text, refusals, manual steps for the new UI in both languages|PASS|PASS|一致|
|W183 R9 guided mode (new UI) highlights 「新增 ▾」 without pressing it|PASS|PASS|一致|
|W183 R9 native 外掛頁「新增 ▾」: glass chip top-right, a popover list with three items + MCP hint (accessibility ids), a Pod operation lease; self-tests registered|PASS|PASS|一致|
|W183 R9 pluginNewMenu (native 外掛頁「新增 ▾」): opens only that dialog — nothing filled, ticked or created; archive only highlights; one-time op; the App can ask whether it is still open|PASS|PASS|一致|
|W183 R9 pod connector (new UI): Connection must be Server URL — Tunnel selected → press Server URL and read back; stuck, unreadable, contradictory or unrecognised → refused, never Tunnel|PASS|PASS|一致|
|W183 R9 pod connector (new UI): OAuth — a non-OAuth default is switched and read back; conflicting value sources, "OAuth API key", two auth controls → never Create|PASS|PASS|一致|
|W183 R9 pod connector (new UI): the menu item must be exactly one 建立 MCP 應用程式 inside the menu this 新增 opened; the other two, stale menus, outside or decoy items are never chosen|PASS|PASS|一致|
|W183 R9 pod connector (new UI): 新增 ▾ → only 建立 MCP 應用程式; fills Name + exact URL, keeps Server URL and the default OAuth untouched, never ticks the risk box|PASS|PASS|一致|
|W183 R9 審查 (Claude \#12): the Advanced OAuth settings button is never taken for the Authentication control, even with aria-haspopup|PASS|PASS|一致|
|W183 R9 審查 (Claude \#3, \#10): a second run while the dialog is still open never presses the Icon 「＋」 or Create; an unrelated extra checkbox → "checkbox", nothing ticked|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N1): rewriting Array.prototype.push, Map/WeakMap methods, the Event.prototype.target getter or the checked getter cannot forge "the user ticked it"|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N2, N3): a re-pointed or foreign <label>, label.click() by the page, Enter, a click before the hand-back or in an earlier round never count|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N4): detached-and-reattached, moved into a new inner form, form attribute changed, cancelled (connectorAbort) or left the page → the record is void for good|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N5): OAuth is positively verified for select and radio — unknown value, ARIA conflict, contradictory or double-selected radios → never Create|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N6): Connection with real input radios — consistent state works; checked vs data-state contradiction → refused, never Tunnel|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 N9; R9c C8): the whole form is the warning snapshot — an over-long form → warning_unbounded; a changed keyword-free clause is caught even when the warning container holds a button, the tick box or a disclosure|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 \#2): only a real user click (isTrusted) on the handed-over box counts; the page ticking it, Tab passing over it, a replaced form or a replayed confirmation never lead to Create|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 \#3): every Pod command must carry the App key — the page's own script (no key, wrong key, un-keyed script) is dropped silently|PASS|PASS|一致|
|W183 R9 審查 (GPT-6 \#6, \#7): the URL goes only into a clearly-marked URL field (never Description); a changed warning block (incl. its link text) is handed back|PASS|PASS|一致|
|W183 R9c (GPT-6 C1): a page lying through String.prototype.toLowerCase (basic → oauth) or JSON / toJSON cannot flip a decision or the reported result; a missing capability → unsafe_env|PASS|PASS|一致|
|W183 R9c (GPT-6 C1): inside the SAFE-CHAIN regions the Pod script calls no page-rewritable method directly (static)|PASS|PASS|一致|
|W183 R9c (GPT-6 C1): with every page-rewritable built-in and DOM accessor replaced, the SAFE-CHAIN never calls a replaced one and every decision stays the same|PASS|PASS|一致|
|W183 R9c (GPT-6 C2): after the user unticks, the page ticking it back (in its click handler or a microtask) leaves no valid proof|PASS|PASS|一致|
|W183 R9c (GPT-6 C3): a same-document round trip with no DOM change, a navigation that bypasses History.prototype, or a navigation the native side reports → the confirmation is void for good|PASS|PASS|一致|
|W183 R9c (GPT-6 C5, C6): input combobox live value, radio visible label vs aria-label, data-state mixed and aria-current=false are never taken as OAuth / Server URL|PASS|PASS|一致|
|W183 files stay private-safe: no private domain, host or account literals in the new sources|PASS|PASS|一致|
|W184 AB (F45 \#3): closing from bubble mode fades the content out first (0.10 s), the shell under the box, then puts the box away and shrinks; reopening mid-fade turns back|PASS|PASS|一致|
|W184 AB (H4 review \#9): Esc with the DM mode card open closes only the card; the box stays; the next Esc takes the usual order|PASS|PASS|一致|
|W184 AB H12: the streaming slide really streams — every update reaches the list, none reaching it fails|PASS|PASS|一致|
|W184 AB R2 (GPT-6 G3c \#4): a form change keeps the message being read — the first one whose start shows below the top bar|PASS|PASS|一致|
|W184 AB docked: the main-window DM button and the open docked box never show together; open grows from it, close shrinks back (same F45 shell)|PASS|PASS|一致|
|W184 AB: one top bar for the whole phone (inner landscape too); ✕ and the size button are gone|PASS|PASS|一致|
|W184 F3T regression self-test (GPT-6 F3 \#4, \#5): bottom anchor, reading old messages, composing input, start cost, always settles|PASS|PASS|一致|
|W184 F3T the form change settles on its timer, never on a display link in the product (R5 "display link stopped")|PASS|PASS|一致|
|W184 G2c／G2d new tab: 新分頁 in the sidebar, ＋ in the overview and the search box, ⌘⌥T in the DM box — a blank general tab, the caret in the centered search; full = one sentence|PASS|PASS|一致|
|W184 G2d: no fades on the sidebar — the main window's Browser space sidebar has none (the 09-29 fade went with the DM-only column)|PASS|PASS|一致|
|W184 H4 fix (review \#1, \#2, \#3, \#5): each turn carries the card — model restart, per-turn ultrawork per thread, remote serialization|PASS|PASS|一致|
|W184 H4 fix (review \#4): a slider only takes a press where it is visible (visibleRect, the card's scrolling viewport)|PASS|PASS|一致|
|W184 H4 fix (review \#6): one keyboard and focus path for every entry: Esc first, keys to the card, IME first, focus back|PASS|PASS|一致|
|W184 H4 fix round 2 (review H4b): delivered only when the engine or primary takes the turn; newest remote choice kept; one send lock; strict fields; keyboard visible; power beside S～XXL; whole lines|PASS|PASS|一致|
|W184 H4 round 4: self-tests switch themes without touching the shared stored theme; pixel self-tests pin their theme|PASS|PASS|一致|
|W184 R: pairing body yields height without losing code, copy, warning, or R12 left-page placement|PASS|PASS|一致|
|W184 R: second temporary click is not swallowed; consent stays explicit and per-chat|PASS|PASS|一致|
|W185 Coder initialization and hydration use Sol medium Fast, preserving explicit controls|PASS|PASS|一致|
|W185 M2 S/M/L/XL/XXL map to low/medium/high/xhigh/max, with legacy XXL fallback|PASS|PASS|一致|
|W185 M2 Ultra is the explicit last glass stop, excluded from pointer and keyboard sliders, with quota warning|PASS|PASS|一致|
|W185 M2 extended values retain Codex/gateway spelling and cap Claude at existing xhigh|PASS|PASS|一致|
|W185 M2 route capabilities exactly match Codex 0.160 built-in levels; old models stay unchanged|PASS|PASS|一致|
|W185 M2 unsupported extended values are capped at hydration, switching, persistence, send and native goal|PASS|PASS|一致|
|W185 all GPT-6 routes lead the picker; previous routes remain selectable|PASS|PASS|一致|
|W185 catalog is explicit, L1 readonly skillet, L2 CU, no approval/start/batch tool|PASS|PASS|一致|
|W185 live turns recognize all four GPT-6 models even without a supplied model|PASS|PASS|一致|
|W185 permission restoration precedes failure latch, transient failures back off without clearing safety|PASS|PASS|一致|
|W185 status truth: partial connection survives adapter errors; node reasons and live start reach visible/AX surfaces|PASS|PASS|一致|
|W185 trait lists, task fallback and collaboration labels include new models|PASS|PASS|一致|
|W185 ultrawork changes only fallback roles, not saved configuration|PASS|PASS|一致|
|W185P code clipboard expires and clears on close without logging, persistence or protocol changes|PASS|PASS|一致|
|W185P compiled production input, feedback and private clipboard scenarios|PASS|PASS|一致|
|W187 device settings retired the W185 pairing controls and direct changes|PASS|PASS|一致|
|W187 fleet tools boundary self-test runs clean (external AI and SSH cannot call fleet tools)|PASS|PASS|一致|
|W187 no UI rewrite; fleet extensions bind to existing HMAC and W78 transport|PASS|PASS|一致|
|W187 production surfaces read verified graph and preserve backend authority|PASS|PASS|一致|
|W187 readonly graph, permissions, list, refusal, toolbar and staff render eight PNGs|PASS|PASS|一致|
|W187 signed fleet: production pairing, offline enrollment, filtered one-way management, attacks and revocation|PASS|PASS|一致|
|W187 設備列收合顯示名字、角色與狀態；展開只看版本、路徑與簽章|PASS|PASS|一致|
|W187 設備頁只顯示群組；私訊框處理變更，側欄仍保留遠端專案入口|PASS|PASS|一致|
|W187R2: isolated real pairing, revoked owner sync, mixed pins, system channel and finite cutoff|PASS|PASS|一致|
|W187a2 v2 graph: eight exact key/capability sets, signed changes, locked directions, private SUB view and v1 migration|PASS|PASS|一致|
|W187a3: dual-signature primary rotation, interrupted four checkpoints and immediate revocation|PASS|PASS|一致|
|W187c device entry lives in assistant DM and remains independent of canSend/model authentication|PASS|PASS|一致|
|W187c physical card confirmation, same store token, and local-only transfer path|PASS|PASS|一致|
|W187c sandbox card offers only another TATWO computer; managed consent stays on joining computer|PASS|PASS|一致|
|W187c tool boundary has no confirmation or enrollment-secret parameters|PASS|PASS|一致|
|W187c2 bridge registers and dispatches only the three assistant fleet tools|PASS|PASS|一致|
|W187c2 external MCP with forged thread identity cannot list or call fleet tools; unavailable App fails closed|PASS|PASS|一致|
|W187c2 preview compares final changes and invite cancel follows explanatory text|PASS|PASS|一致|
|W187g role preview does not describe designation as a device rename|PASS|PASS|一致|
|W187g ruling 1: no automatic SUB primary; assistant exposes designation and cancellation|PASS|PASS|一致|
|W187g ruling 2: staff peers unavailable; MAIN publication migrates existing arrows|PASS|PASS|一致|
|W187g ruling 3: consent, preview and device views explain designation without colleague control|PASS|PASS|一致|
|W187g runtime: designation security, migration and exact controller sets|PASS|PASS|一致|
|W19 real HTTP download: progress changes, polling fallback, unknown length, cancellation and errors|PASS|PASS|一致|
|W19 source guards: session delegate, synchronous move, polling, monotonic progress and speed copy|PASS|PASS|一致|
|W190 assistant introduction and actual packaged preamble describe OS and user familiarity|PASS|PASS|一致|
|W190 first setup step combines assistant model selection and login|PASS|PASS|一致|
|W190 isolated self-test renders three real setup pages and exercises real menu selection|PASS|PASS|一致|
|W190 setup and composer use the same options, setter, current model and updates|PASS|PASS|一致|
|W192 A1 hidden idle Pod receives native visibility; active work wakes before dispatch|PASS|PASS|一致|
|W192 I1 one glass reasoning control; Ultra stays an explicit choice|PASS|PASS|一致|
|W192 I2 CLI capability chip presents conversation labels while retaining protocol IDs|PASS|PASS|一致|
|W192 I2 mode card uses conversation language without redundant explanation|PASS|PASS|一致|
|W192 I3 dark override is DEBUG-only and dark evidence is rendered|PASS|PASS|一致|
|W192 I3 pastel glass fill uses dark ink for readable selected labels|PASS|PASS|一致|
|W192 U2 per-turn regressions follow capability reports and explicit effort after level|PASS|PASS|一致|
|W192-02 read-only warning appears above composer; restore requires confirmation and date|PASS|PASS|一致|
|W192-04 executable diagnostics stay inside collapsed details|PASS|PASS|一致|
|W192-05 PR confirmation and submit use glass chips without blue prominent style|PASS|PASS|一致|
|W192-06 assistant guidance reflects full connection and current product names|PASS|PASS|一致|
|W192-07 model catalog launches once at startup and is independent of login refresh|PASS|PASS|一致|
|W194 message viewports avoid the floating top bar on every target; the shared frame and fade remain|PASS|PASS|一致|
|W194-1 stop preparation is bounded and never releases an unknown send|PASS|PASS|一致|
|W194-10 login failure has a settings action; restore failures are plain language|PASS|PASS|一致|
|W194-10 normalized login failure retains the settings exit and non-login errors do not gain it|PASS|PASS|一致|
|W194-11 model labels survive persisted replies and catalog loss; login refreshes models|PASS|PASS|一致|
|W194-2 Coder allows dormant sends and runner waits for wake|PASS|PASS|一致|
|W194-3 DM stop keeps consuming the receipt and uses a neutral stopped note|PASS|PASS|一致|
|W194-4 offscreen parking window always blocks capture|PASS|PASS|一致|
|W194-5 shared four-form message viewport reserves the floating header|PASS|PASS|一致|
|W194-6 plan controls use Chinese and shared glass chips|PASS|PASS|一致|
|W194-7 connection copy uses the current Plugin path and build name|PASS|PASS|一致|
|W194-8 login details follow the provider row and align to its leading edge|PASS|PASS|一致|
|W194-9 read-only message states that sending is blocked|PASS|PASS|一致|
|W194-A2 blocking subprocess probes use an owned thread, never a shared worker pool|PASS|PASS|一致|
|W194-A2 login status reads the completed runtime snapshot without spawning a version probe|PASS|PASS|一致|
|W194-S1 a real ad-hoc signature cannot become trusted by printing Developer ID and expected Team|PASS|PASS|一致|
|W194-S1 trust uses an Apple Developer ID and expected Team requirement, never printed metadata|PASS|PASS|一致|
|W195 Coder keeps a background send lease through model and project preparation|PASS|PASS|一致|
|W195 composer always offers Stop for a running TAP turn, including a newly typed command|PASS|PASS|一致|
|W195 hides only the legacy TAP startup system row without rewriting stored history|PASS|PASS|一致|
|W195 queued wake remains a writing reply without a startup announcement or system message|PASS|PASS|一致|
|W195 startup watchdog and send readiness share a 60 second budget|PASS|PASS|一致|
|W195 wake regression uses the real TAP, Coder delivery, DM and Space with a hidden-sensitive fake Pod|PASS|PASS|一致|
|W196 temporary Node locator executes isolation, regular-file and sandbox guards|PASS|PASS|一致|
|W197 real Pod script installs no conversation/network hooks on Dots or a display-only redirect|PASS|PASS|一致|
|W197 returning clears display-only mode before the original TAP installs|PASS|PASS|一致|
|W198 MCP declares native model, calling-room ticket, bounded wait and stop schema|PASS|PASS|一致|
|W198 MCP forwards known fields unchanged for authoritative native validation|PASS|PASS|一致|
|W198 MCP rejects supplied identity and unknown keys before App socket|PASS|PASS|一致|
|W198 MCP requires startup-bound local thread for dispatch and stop|PASS|PASS|一致|
|W198 dispatch waits beyond 45 seconds, returns its receipt, and times out at its own deadline|PASS|PASS|一致|
|W198 stop is processed over the same MCP connection while dispatch waits|PASS|PASS|一致|
|W199 actual main list and search handlers reject missing items rather than declaring an empty result|PASS|PASS|一致|
|W199 actual project handler follows cursors without publishing a partial or malformed list|PASS|PASS|一致|
|W20 helper passes both quoted layer paths and leaves runtime empty when reused|PASS|PASS|一致|
|W20 prefetch plans only needed layers and aggregates byte offsets|PASS|PASS|一致|
|W20 production runtime reuse decision: hash, missing paths, old apps and unsafe metadata|PASS|PASS|一致|
|W20 real assembly: local reuse, runtime fetch/cache, old release and sealed fallback|PASS|PASS|一致|
|W200 HTTP body that never arrives is still a terminal failure within five seconds|PASS|PASS|一致|
|W200 Markdown explaining an error with an ordinary Try again action is not a failure|PASS|PASS|一致|
|W200 Retry box without alert/color has positive error evidence|PASS|PASS|一致|
|W200 SSE event name alone identifies a reasoning recap heading and omits its body|PASS|PASS|一致|
|W200 a cumulative thoughts event selects its newest heading|PASS|PASS|一致|
|W200 a final error SSE frame without a trailing blank line is still terminal|PASS|PASS|一致|
|W200 a normal envelope type does not hide a failed message status|PASS|PASS|一致|
|W200 a single reasoning heading remains positive thinking evidence without repeated bytes|PASS|PASS|一致|
|W200 errors are bounded, sanitized and never enter diagnostics|PASS|PASS|一致|
|W200 explicitly marked empty detail object still terminates with a generic provider error|PASS|PASS|一致|
|W200 explicitly marked empty error object still terminates with a generic provider error|PASS|PASS|一致|
|W200 full reasoning content in an analysis channel is never answer text|PASS|PASS|一致|
|W200 known reasoning never forwards a thinking bubble recap body through DOM fallback|PASS|PASS|一致|
|W200 maximum-length page alert: You have reached the maximum length for this conversation.|PASS|PASS|一致|
|W200 maximum-length page alert: 這則對話長度已達上限，請開啟新對話。|PASS|PASS|一致|
|W200 non-2xx body: code|PASS|PASS|一致|
|W200 non-2xx body: detail|PASS|PASS|一致|
|W200 non-2xx body: detail [#2]|PASS|PASS|一致|
|W200 non-2xx body: error|PASS|PASS|一致|
|W200 non-2xx caps body reads at 2KB and falls back to HTTP code|PASS|PASS|一致|
|W200 old page alert and a hidden new alert do not fail the current turn|PASS|PASS|一致|
|W200 page error: {"class":"text-error"}|PASS|PASS|一致|
|W200 page error: {"class":"text-red-500"}|PASS|PASS|一致|
|W200 page error: {"data-testid":"conversation-error"}|PASS|PASS|一致|
|W200 page error: {"role":"alert"}|PASS|PASS|一致|
|W200 page: normal reply, quoted error, alert outside conversation and Pro placeholder do not fail|PASS|PASS|一致|
|W200 persistent thinking evidence still respects the 35 minute hard deadline|PASS|PASS|一致|
|W200 poll checks new provider errors within five seconds even after backoff reaches its maximum|PASS|PASS|一致|
|W200 poll error: fresh-node|PASS|PASS|一致|
|W200 poll error: root-detail|PASS|PASS|一致|
|W200 poll error: root-error|PASS|PASS|一致|
|W200 poll ignores an error node from the previous turn|PASS|PASS|一致|
|W200 polling a finished thoughts content node never publishes its body or marks the answer finished|PASS|PASS|一致|
|W200 polling an analysis node neither leaks its body nor replays the previous answer|PASS|PASS|一致|
|W200 polling never attributes the original parent error with no timestamp to this round|PASS|PASS|一致|
|W200 progress headings only: /message/content/thoughts/0/title|PASS|PASS|一致|
|W200 progress headings only: message|PASS|PASS|一致|
|W200 progress headings only: reasoning_recap|PASS|PASS|一致|
|W200 progress headings only: thoughts|PASS|PASS|一致|
|W200 progress title is at most 80 characters; body-only thoughts disclose no text|PASS|PASS|一致|
|W200 quarantined empty original stream fails after three minutes without reading another conversation|PASS|PASS|一致|
|W200 quoted credentials, authorization schemes and relative URL parameters are redacted locally|PASS|PASS|一致|
|W200 reason: context_length_exceeded|PASS|PASS|一致|
|W200 reason: conversation_too_long|PASS|PASS|一致|
|W200 reason: max length|PASS|PASS|一致|
|W200 reason: maximum length|PASS|PASS|一致|
|W200 reason: too long|PASS|PASS|一致|
|W200 reason: 对话过长|PASS|PASS|一致|
|W200 reason: 對話太長|PASS|PASS|一致|
|W200 stream: delta error fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: detail object fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: detail string fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: error content type fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: error object fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: error string fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: event error, message/code fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: event error, plain string fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: message metadata fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: metadata error_code + content fails in under 5 seconds|PASS|PASS|一致|
|W200 stream: type error fails in under 5 seconds|PASS|PASS|一致|
|W200 the error type code classifies length even when the error text is generic|PASS|PASS|一致|
|W200 thinking evidence: async survives 3 minutes|PASS|PASS|一致|
|W200 thinking evidence: bytes survives 3 minutes|PASS|PASS|一致|
|W200 thinking evidence: placeholder survives 3 minutes|PASS|PASS|一致|
|W200 thinking evidence: progress survives 3 minutes|PASS|PASS|一致|
|W200 thinking evidence: stop survives 3 minutes|PASS|PASS|一致|
|W200 three minutes accepted without evidence confirms conversation once then fails|PASS|PASS|一致|
|W200 typed context length error without a message still classifies its code|PASS|PASS|一致|
|W201 automatic assistant fallback is quiet; blocked actions stay at the composer|PASS|PASS|一致|
|W201 top line: refused actions only, shared settings list, expandable glass|PASS|PASS|一致|
|W202 normalization preserves suffix and Unicode behavior|PASS|PASS|一致|
|W203-3 git add -A cannot stage dispatch replies even in nested rooms|PASS|PASS|一致|
|W203-4 real Pod localText masks short passwords, paths, email and phone before truncating|PASS|PASS|一致|
|W205 optional recovery appends to the existing draft|PASS|PASS|一致|
|W205-2 local missing record is quiet and same reason can be dismissed|PASS|PASS|一致|
|W205-3 reply protection is established through the pinned directory before output|PASS|PASS|一致|
|W205-4 generic failed events do not claim a confirmed provider failure|PASS|PASS|一致|
|W205-4 only unconfirmed results are locked; bounded receipts support explicit release|PASS|PASS|一致|
|W205-4 watchdog cancellation preserves unknown receipts until explicit owner release|PASS|PASS|一致|
|W205-5 caller sidecar closure also cancels in-flight dispatch without erasing uncertain results|PASS|PASS|一致|
|W205-5 live dispatcher deadline protects caller and caller stop cancels dispatch|PASS|PASS|一致|
|W205-6 relative/API paths and bare timestamps survive; real local paths and phones are masked|PASS|PASS|一致|
|W205-6 shared redactor preserves file URL privacy while allowing relative paths|PASS|PASS|一致|
|W207 phone labels preserve product/resolution text and mask Taiwan contacts|PASS|PASS|一致|
|W207 repeated thinking headings keep activity but publish only changed progress|PASS|PASS|一致|
|W208 collision never changes the connector name or presses Create again|PASS|PASS|一致|
|W210 native regressions and twenty measured reconnect rows retain isolated UI evidence|PASS|PASS|一致|
|W210-1 account A to B while connectorDelete waits never presses final Delete|PASS|PASS|一致|
|W211 real bindings, fake DDC timing, keyboard default and isolated synchronization failures|PASS|PASS|一致|
|W212 actual callback judgement stays immediate with main blocked and defers one adjustment|PASS|PASS|一致|
|W212 supported pass reasons append; undecodable events are silent and periodic trimming retains 200|PASS|PASS|一致|
|W213 Always: real Coder scroll views never show permanent scrollbars|PASS|PASS|一致|
|W214 environment access uses logo circles and a collapsed section in Login|PASS|PASS|一致|
|W214-1: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-2: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-3: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-4: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-5: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-6: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-7: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-8: production behavior and native accessibility tree|PASS|PASS|一致|
|W214-9: production behavior and native accessibility tree|PASS|PASS|一致|
|W215: Coder logo column, turn details, approvals, centered history and live progress|PASS|PASS|一致|
|W216 existing OS mapping description remains confirmed by the same command|PASS|PASS|一致|
|W216 negative: empty and whitespace names never call API|PASS|PASS|一致|
|W216 negative: ordinary Space project accepts a name without OS mapping metadata|PASS|PASS|一致|
|W216 negative: rejected or malformed project never reports success|PASS|PASS|一致|
|W217 Coder baseline: voice operations are rejected before app-server; text provider survives config preparation|PASS|PASS|一致|
|W217 Pod: End voice mode reports live, then really stops|PASS|PASS|一致|
|W217 Pod: disabled control fails within five seconds, not a false live session|PASS|PASS|一致|
|W217 Pod: hidden control fails within five seconds, not a false live session|PASS|PASS|一致|
|W217 Pod: missing control fails within five seconds, not a false live session|PASS|PASS|一致|
|W217 Pod: stop during navigation cancels the pending start before it can click|PASS|PASS|一致|
|W217 Pod: stop guard also closes a late localized voice session|PASS|PASS|一致|
|W217 Pod: 結束語音模式 reports live, then really stops|PASS|PASS|一致|
|W217 Pod: 结束语音 reports live, then really stops|PASS|PASS|一致|
|W217b Pod: page enters voice five seconds after click|PASS|PASS|一致|
|W217b Pod: page never responds waits eight seconds, then fails by twelve|PASS|PASS|一致|
|W217b Pod: stop while enteringVoice takes effect immediately and invalidates start|PASS|PASS|一致|
|W217b Pod: stop while findingButton takes effect immediately and invalidates start|PASS|PASS|一致|
|W217b Pod: voice button appearing after three seconds can still start|PASS|PASS|一致|
|W219-1: Coder artifacts start collapsed, open through the logo, and collapse again in both themes|PASS|PASS|一致|
|W22 exact delta naming, size boundary and quoted handoff|PASS|PASS|一致|
|W22 manifests, mode/link/new/deleted files and production offline assembly|PASS|PASS|一致|
|W22 production selection falls through delta, layer, then full without replacing installed App|PASS|PASS|一致|
|W221c first signed push adopts only an already pinned primary; attack fixtures fail closed|PASS|PASS|一致|
|W221c unmanaged keys survive production transfer, handback and revocation on five fixtures|PASS|PASS|一致|
|W221c unmanaged keys survive update, pairing, revocation and removal; restricted duplicates fail closed|PASS|PASS|一致|
|W221d claimed phase differing from the verified decoded receipt is refused in both directions|PASS|PASS|一致|
|W221d non-fleet legacy ACK preserves old unsplit pin and handoff guards|PASS|PASS|一致|
|W221h revoke backup-failure|PASS|PASS|一致|
|W221h revoke legacy|PASS|PASS|一致|
|W221h revoke repeat|PASS|PASS|一致|
|W221h revoke scope|PASS|PASS|一致|
|W221h revoke scope-roster|PASS|PASS|一致|
|W221h revoke shared|PASS|PASS|一致|
|W224 native fixtures: targeted navigation, cached catalog, shared memory actions and current build card|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W224-1 targeted Login entries expand and scroll; ordinary Login stays collapsed|PASS|PASS|一致|
|W224-2 unrelated or undecodable events are silent; diagnostics append and trim periodically|PASS|PASS|一致|
|W224-3 cached project catalogs refresh silently and only first-load failures show errors|PASS|PASS|一致|
|W224-4 Coder uses the same memory content, actions and retryable detailed errors|PASS|PASS|一致|
|W224-5 every HandsBuild copy member has a production consumer, not just retired UI selftests|PASS|PASS|一致|
|W225 group: actual Swift engine, fake participants, no network|PASS|PASS|一致|
|W225b2: real group engine, fake clock and TAP adapters|PASS|PASS|一致|
|W225b4 actual group engine with fake participants|PASS|PASS|一致|
|W225b4 composer admits busy group and bypasses native steering|PASS|PASS|一致|
|W225b4 explicit lifecycle and Coder relay entries exist without dead conversation hook|PASS|PASS|一致|
|W225b4 miscellaneous actual group regressions|PASS|PASS|一致|
|W225b5-1 actual Swift regressions|PASS|PASS|一致|
|W225b5-4 actual Swift regressions|PASS|PASS|一致|
|W225b5-4 queued and unsent labels render in the existing user bubble|PASS|PASS|一致|
|W225b5-5 admits a group before classifying only the current project|PASS|PASS|一致|
|W225b5-5 tool-step recording never sorts the transcript|PASS|PASS|一致|
|W225b5-6 actual Swift regressions|PASS|PASS|一致|
|W225b5-7 actual Swift regressions|PASS|PASS|一致|
|W226 app hooks stay local and do not expose events as MCP|PASS|PASS|一致|
|W226 every requested source has a minimal event hook|PASS|PASS|一致|
|W226 storage appends on a serial queue; monthly rollover uses OSClock|PASS|PASS|一致|
|W227-1 sidebar update has no unused navigation callback|PASS|PASS|一致|
|W227-2 each fresh process trims an oversized diagnostic log on its first event|PASS|PASS|一致|
|W227-3 acceptance checks retained short copy across hidden states and repair titles|PASS|PASS|一致|
|W227-4 root catalog acceptance waits for completion and verifies a replacement list|PASS|PASS|一致|
|W227-5 docs contain no concrete local account paths|PASS|PASS|一致|
|W229 group log uses project ID, stable metadata notes and local append API|PASS|PASS|一致|
|W229 has one send provenance mechanism for both event actor and group admission|PASS|PASS|一致|
|W229 plan button uses normal routing with explicit nonhuman source and restores its draft|PASS|PASS|一致|
|W229 real group lifecycle emits membership and transfer events and preserves Ledger|PASS|PASS|一致|
|W23 real HTTP: server restart, disk resume across processes, SHA and retry policy|PASS|PASS|一致|
|W23 source guards: durable resume, offset, cancellable unbounded backoff and release-scoped copy|PASS|PASS|一致|
|W230 Codex real sidecar accumulates native output once, handles repeated and stale notifications|PASS|PASS|一致|
|W230 local storage, scope, event privacy and Events line budget|PASS|PASS|一致|
|W230 production growth stays within 900 net lines|PASS|PASS|一致|
|W230 w230pets native acceptance, all backend requirements in isolated environment|PASS|PASS|一致|
|W230b UI uses only public pet APIs and shared transcript; no Coder selection changes|PASS|PASS|一致|
|W230b replaceable PetSkin owns colors and visual measurements|PASS|PASS|一致|
|W230b w230petsui native acceptance and all screens in supported theme appearances|PASS|PASS|一致|
|W230c new sessions and polish preserve the room boundary and production budget|PASS|PASS|一致|
|W231 managed read, trading read-only and group transport gates use actual facades|PASS|PASS|一致|
|W231 refuses managed reads before obtaining transcript or decoding cursors|PASS|PASS|一致|
|W231 retains browsing refusal before DM source mutation|PASS|PASS|一致|
|W231 retains managed approval restriction and sidecar PID/start-time checks|PASS|PASS|一致|
|W232 legacy SSH bootstrap, real gate, metadata-only ledger and final managed check|PASS|PASS|一致|
|W234 conversation navigation remains display-only until the native TAP restores|PASS|PASS|一致|
|W234 display-only Pod contains no conversation DOM or network hooks|PASS|PASS|一致|
|W234 page hints and injected instructions are never read or reported|PASS|PASS|一致|
|W235 MCP discovery, secret-free imports and confirmed updates run clean|PASS|PASS|一致|
|W236 sigils and three-party Coder UI isolated acceptance|PASS|PASS|一致|
|W238 actual TAP queue and tail behavior regressions|PASS|PASS|一致|
|W239 change proposals require human approval and enforce patch boundaries|PASS|PASS|一致|
|W24 actual offline installer: 134MB gates before ZIP and before rename, old bundle intact; timed successful assembly|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W24 cache and Applications space gates run before bytes, after verification and before handoff|PASS|PASS|一致|
|W24 clone-first fallback preserves real fake bundle contents and measures assembly|PASS|PASS|一致|
|W24 detection starts prefetch only for an install-ready newer release, all three triggers share check|PASS|PASS|一致|
|W24 disk preflight uses candidate uncompressed size x2 and fake df fails closed|PASS|PASS|一致|
|W24 helper polls 0.2 seconds with unchanged total wait and emits installSeconds|PASS|PASS|一致|
|W24 network starts fail-closed, rejects expensive/constrained paths, allows explicit download|PASS|PASS|一致|
|W24 no repeated candidate deep verify or repeated continuity after staging rename; timing ends at open|PASS|PASS|一致|
|W24 offline restart caches tag-pinned script and hash-bound metadata, namespaced by repository|PASS|PASS|一致|
|W24 offline transport refuses uncached URLs, never falls through to real curl|PASS|PASS|一致|
|W24 production Swift state methods: metered override, space gate, candidate cancellation, ready-only handoff|PASS|PASS|一致|
|W24 releases without a size manifest (v2.0.5 and earlier) still install using compressed size ×4|PASS|PASS|一致|
|W240 MCP acceptance runs clean|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W241 pet and group acceptance runs clean|PASS|PASS|一致|
|W242 MCP third-round acceptance runs clean|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W243 input, pets and TAP behavior acceptance|PASS|PASS|一致|
|W244 change proposals and composer acceptance|PASS|PASS|一致|
|W245 MCP fourth-round acceptance runs clean|PASS|PASS|一致|
|W246 E1–E7 acceptance and identical Swift/JS URL corpus|PASS|PASS|一致|
|W25 production version binding: equality mandatory, downgrade opt-in never bypasses binding|PASS|PASS|一致|
|W250 App/Sources contains no removed enamel types|PASS|PASS|一致|
|W250 picker and browser design checks exactly match v2.0.22|PASS|PASS|一致|
|W250 removes enamel registration and fixtures and registers picker acceptance|PASS|PASS|一致|
|W253 sandbox refuses five families, bypasses and stale proofs through the production handler|PASS|PASS|一致|
|W255 H1: real store code uses fake Security calls only; migration preserves data and retries failures|N/A|PASS|W255 新增測試；PASS|
|W255 H2: password gate rejects spoof, iframe, unapproved fill and redirect; bound pairing needs no second confirmation|N/A|PASS|W255 新增測試；PASS；W263 按 W255c 現況改名|
|W255 test launcher refuses Keychain and signing commands without running even a synthetic executable|N/A|PASS|W255 新增測試；PASS|
|W26 SIGKILL inside production rename window is recovered by the next installer|PASS|PASS|一致|
|W26 actual Swift run liveness removes stale labels and acknowledges newest result by UUID|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W26 actual package shell never exposes output or gh command on candidate/archives failure|PASS|PASS|一致|
|W26 archive gates fail closed for each unpack/verify/difference gate and bind actual hashes|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W26 candidate gates reject each failed check on a fake bundle, including reverse DR|PASS|PASS|一致|
|W26 curl 18 re-invokes curl and resumes from existing bytes on second attempt|PASS|PASS|一致|
|W26 helper abnormal TERM writes a terminal failure instead of restart installation|PASS|PASS|一致|
|W26 install-ready requires one matching candidate hash; legacy name-only marker binds via .sha256 instead|PASS|PASS|一致|
|W26 persisted transactions restore interrupted rename and leave live/committed runs alone|PASS|PASS|一致|
|W26 terminal helper receipt is idempotent; two run IDs never overwrite each other|PASS|PASS|一致|
|W26/W64 retention leaves legacy temp directories outside UpdateArchives untouched|PASS|PASS|一致|
|W30 80 MiB / 2,000 resource files: delta_tree <10s, one hash batch, final seal rejects same-size reuse corruption|PASS|PASS|一致|
|W30 production selection prefers reusable runtime, otherwise delta must be < app/4|PASS|PASS|一致|
|W31 helper passes prepared delta/layered route unchanged to the installer|PASS|PASS|一致|
|W31 native installer economy keeps online runtime reuse layered, but accepts offline delta-only|PASS|PASS|一致|
|W31 offline delta-only executes production delta assembly and verifies the final real code seal|PASS|PASS|一致|
|W31 offline delta-only wins economy; app-only and online reusable runtime select layered; prepared route wins|PASS|PASS|一致|
|W31 prepared archives carry selection into helper environment; NEW-7 CI explicitly includes regression suites|PASS|PASS|一致|
|W39 Browser-only shortcut, bookmark drops, blank-area menu and add-space control|PASS|PASS|一致|
|W40 in-memory production registry/projection: grouping, close, move, bookmark and guards|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W40 session surface has folders, read-only lanes, hollow page dot and no creation/drop entry|PASS|PASS|一致|
|W40-fix: session space rows, dots and lane card use BrowserSidebarMetrics tokens (no bare sizes)|PASS|PASS|一致|
|W42 production mark and action fixture: intent, integer %, false/true confirm, stale candidate and duplicate taps|PASS|PASS|一致|
|W42 shared three-state UI preserves ready-only handoff and hides background progress|PASS|PASS|一致|
|W42-fix hand-off terminate bypasses the Island terminate confirmation exactly once and progress publishes per 1%|PASS|PASS|一致|
|W45-fix: popups inherit the opener actor/ad-block flags and late permission replies stop at close_requested|PASS|PASS|一致|
|W46-fix: registry saves off the main actor and keeps unseen tabs on stale snapshots|PASS|PASS|一致|
|W48-fix: bridge installs navigator.modelContext (W3C) plus document alias; Island title within 14 characters|PASS|PASS|一致|
|W49: independent sheet entrypoint and protected integration surfaces|PASS|PASS|一致|
|W49: real Swift importers, coordinator, stores and view; synthetic profiles only|PASS|PASS|一致|
|W49b: consent-based Safe Storage import, CSV fallback, no secret logs or extension installation|PASS|PASS|一致|
|W50-fix: Keychain store falls back to the login keychain on errSecMissingEntitlement and reads both variants|PASS|PASS|一致|
|W50: real Swift vault/planners and settings compile; behavioral/security fixture|PASS|PASS|一致|
|W50: secrets are device-only Keychain items, production authentication never falls back|PASS|PASS|一致|
|W50: settings labels, Island confirmation, import notification and privacy lifetimes|PASS|PASS|一致|
|W51 honest extension copy, immutable AI column and W55 diagnostics|PASS|PASS|一致|
|W52-fix: BrowserGeneralSettings tolerates a W47-only settings.json and merge-saves without resetting searchEngine|PASS|PASS|一致|
|W53 chat is a registry window using shared rows and CEF, without duplicate bookmark/state UI|PASS|PASS|一致|
|W53 executes the production native recovery method: shared context, close completion, prefs failure|PASS|PASS|一致|
|W53 native input recovery is scoped, excludes own synthetic events and resets native policy/prefs|PASS|PASS|一致|
|W53 production runtime isolates chat hosts, retains background tabs, sleeps/wakes and closes|PASS|PASS|一致|
|W53 swiftc: two chat tabs, selection, keep/closeWithChat, owner isolation, human recovery|PASS|PASS|一致|
|W53b WK never mounts a surface; bridge returns an engine error rather than looking for WK|PASS|PASS|一致|
|W53b durable bookmark migration, retry, unknown profile preservation and delete/undo fixture|PASS|PASS|一致|
|W53b native order cancels callbacks under strict actor before actor transition and human prefs|PASS|PASS|一致|
|W53b production action counter balances nested and throwing methods and marks completion time|PASS|PASS|一致|
|W53b shared surface owns the complete state card and annotation entrypoints use one sheet|PASS|PASS|一致|
|W53b workspace/session row variants keep exact baseline values and no inner workspace selection fill|PASS|PASS|一致|
|W54 accessibility measurement uses actual raw-value identifiers and no group indices|PASS|PASS|一致|
|W54 compact downloads retain search, grouping, selection, clear and native file actions|PASS|PASS|一致|
|W54 deprecated settings aliases point to canonical tokens rather than duplicate literals|PASS|PASS|一致|
|W54 downloads retain real actions and render a compact, progress-aware panel|PASS|PASS|一致|
|W54 every shared row owner carries title, identity and sleep state|PASS|PASS|一致|
|W54 four requested views contain no naked font, padding, frame or corner size|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W54 import keeps all four states, true progress and right-aligned existing actions|PASS|PASS|一致|
|W54 one Island card style serves ask, confirm and info without changing resolution|PASS|PASS|一致|
|W54 settings use numbered warm cards, three-column rows and immutable AI values|PASS|PASS|一致|
|W54 space dots and folder rows expose accessibility identifiers, not just labels|PASS|PASS|一致|
|W54 v10 exact browser geometry has one named-token authority|PASS|PASS|一致|
|W55 change boundaries: policies identical after removing only logging / env override|PASS|PASS|一致|
|W56-fix: host load path treats the exact inert about:blank as allowed (new tabs start there)|PASS|PASS|一致|
|W56-fix: space visibleTabs honours the shipped Info.plist browser flag, not only the env flag|PASS|PASS|一致|
|W57a bridge: human-only menu/find/zoom, background popup and real callback dispatch|PASS|PASS|一致|
|W57a real Swift registry/history/zoom/policy fixtures|PASS|PASS|一致|
|W57a shortcuts are mounted in human Browser/chat-browser only and gated by local focus|PASS|PASS|一致|
|W57a-fix: native Esc defers to the host so an open find bar closes before stop-loading|PASS|PASS|一致|
|W57c actual renderer factory fills only bound visible login fields and dispatches input/change, never submit|PASS|PASS|一致|
|W57c actual submit/Enter capture is trusted, memory-only, deduplicated and removable|PASS|PASS|一致|
|W57c dedicated callbacks and fill are actor, document, origin, generation and revocation gated|PASS|PASS|一致|
|W57c real Swift coordinator/vault/planners: Island allow/deny, save/update/none, settings and stale replies|PASS|PASS|一致|
|W57c values never enter diagnostics, telemetry, agent bridge or interpolated scripts|PASS|PASS|一致|
|W57d Print/PDF fallback remains human, document-bound and signature-checked; DRM is explicit|PASS|PASS|一致|
|W57d actual AppKit coordinator: filters, fullscreen owner/focus/restore and silent PDF revocation|PASS|PASS|一致|
|W57d file dialogs fail closed for agents and stale replies, native panels are per-window|PASS|PASS|一致|
|W57d four native handler surfaces, reduced Chrome 154 UA and unavailable ABI|PASS|PASS|一致|
|W57d fullscreen restores owner geometry/focus and handles Escape even outside renderer focus|PASS|PASS|一致|
|W57d production UA pure function and file dialog callback fixture|PASS|PASS|一致|
|W57e Swift defaults, round-trip, normalized conflicts, number-group reservations and tolerant settings|PASS|PASS|一致|
|W57e custom close action closes only a tab and the empty workspace remains Search, never app termination|PASS|PASS|一致|
|W57e map is mounted in Browser; no hard-coded W/L/R/T in other branches|PASS|PASS|一致|
|W57e only map-derived browser shortcuts, ordered settings and recording UI|PASS|PASS|一致|
|W57e production native recorder handles capture, Esc, Delete and responder isolation|PASS|PASS|一致|
|W58 actor identity survives initial blank tab, mixed contexts and wake without converting human tabs|PASS|PASS|一致|
|W58 actual renderer single-use fill, post/same-origin/form/2FA gates and next-page scan|PASS|PASS|一致|
|W58 isolated services, native actor/form gates, UI labels and no secret tool|PASS|PASS|一致|
|W58 production Swift vault, coordinator, CSV, Touch ID ordering/cache and UI compile|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W58 real MCP schema binds native caller, rejects overrides and strips extra reply fields|PASS|PASS|一致|
|W59 actual TOTP renderer matches autocomplete/name code, same-origin POST, clears code and is single-use|PASS|PASS|一致|
|W59 actual change renderer separates fill/submit, rejects mutation, cancels fields, requires positive result|PASS|PASS|一致|
|W59 approved settings pills, account columns, safe import and human-only password page|PASS|PASS|一致|
|W59 custody channel has no logs, secret-returning tools or HIBP identity fields|PASS|PASS|一致|
|W59 production Swift RFC6238, CSV, both-vault breach rules and every change-stage failure|PASS|PASS|一致|
|W59-fix: breach-policy panel matches approved mockup v3 rows|PASS|PASS|一致|
|W60 actual registry and lease registry: 30 opens, 200 switches, 20 closes, sleep/wake, drain|PASS|PASS|一致|
|W60 diagnostics sanitizes and bounds ten terminations without inventing PID restarts|PASS|PASS|一致|
|W60 production runtime stress: surface exclusivity, native identity retention, sleep removal|PASS|PASS|一致|
|W60 production scheduler obeys immediate/delayed/cancel/overdue/shutdown semantics|PASS|PASS|一致|
|W60 quiet UI and lifetime boundaries stay wired to production|PASS|PASS|一致|
|W60 real navigation-state activity policy: no stuck progress on same-page/stop/error|PASS|PASS|一致|
|W60b actual admission budget holds closing slots, wakes across hosts and never fakes completion|PASS|PASS|一致|
|W60b global runtime: 30 opens, cross-session LRU, flush, wake, warning/critical and notification|PASS|PASS|一致|
|W60b native wiring, secure flags, settings and diagnostics retain honest process semantics|PASS|PASS|一致|
|W60b production policy: memory boundaries, deterministic LRU, selected immunity and pressure|PASS|PASS|一致|
|W60b settings round-trip, old/stale writer compatibility, invalid settings and sleep options|PASS|PASS|一致|
|W60b ten-tab sampler executes and reports unavailable helper RSS as null, not zero/PASS|PASS|PASS|一致|
|W61 does not widen or rewrite any pre-existing allowlist entry|PASS|PASS|一致|
|W61 exported tree passes safety scan and the exact personal-data grep|PASS|PASS|一致|
|W64 A grep forbids fabricated specifications in the runtime stub; fresh nils cannot be refilled from snapshots|PASS|PASS|一致|
|W64 A production hardware summary displays dashes for unavailable fields|PASS|PASS|一致|
|W64 A production inventory: each unavailable field stays nil, real dispatch pressure levels, interval CPU and sysctl truth|PASS|PASS|一致|
|W64 B 52-directory legacy fixture retains one failed diagnosis and the real backup, not delta chunks|PASS|PASS|一致|
|W64 B EXIT success/failure retires only its own stage and keeps the latest failure|PASS|PASS|一致|
|W64 B app gates selected archive bytes before payload download; named safety budget and Island notice are wired|PASS|PASS|一致|
|W64 B legacy backup ordering preserves subsecond recency and cleanup failure keeps recoverable data|PASS|PASS|一致|
|W64 B only the two newest validated backup directories survive|PASS|PASS|一致|
|W64 B rejects outside, sibling, nested, symlink and non-updater paths; preserves unknown and live material|PASS|PASS|一致|
|W66 bookmark rows project the bound tab and stay out of both ordinary tab lists|PASS|PASS|一致|
|W66 browser sidebar and canvas abut; work-space close and pin are labeled live actions|PASS|PASS|一致|
|W66 hover minus closes tabs only and remains keyboard/accessibility reachable|PASS|PASS|一致|
|W66 live Bot and Browser share the approved dot-plus ratio and centered scroll group|PASS|PASS|一致|
|W66 production registry/store: identity, close, folder scope, undo, reopen, persistence and pin|PASS|PASS|一致|
|W66 space capsule overlays the outer shell, not the padded mode section, with one height frame|PASS|PASS|一致|
|W67 Dia toolbar reserves layout height so native page cannot overlap controls|PASS|PASS|一致|
|W67 both appearances use Dashboard glass and semantic readable foregrounds|PASS|PASS|一致|
|W67 click opens; escape, focus loss and outside native clicks collapse without eating the destination event|PASS|PASS|一致|
|W67 collapse shows committed host only and never presents HTTP as locked|PASS|PASS|一致|
|W67 fixture glass opt-in leaves unrelated W54 fixtures byte-identical|PASS|PASS|一致|
|W67 native click, typing, Esc, focus, tab suggestion and light/dark narrow layout|SKIP|SKIP|一致|
|W67 preserves identifier, dynamic binding notifications, open-tab callbacks and reduced motion|PASS|PASS|一致|
|W67 supersedes W54 idle geometry while retaining its editing and dynamic-hint contract|PASS|PASS|一致|
|W68 an unreadable keep receipt is not consent and cannot hide the actionable difference|PASS|PASS|一致|
|W68 changed bundled OR runtime contents re-enable notice after keep|PASS|PASS|一致|
|W68 dangling runtime symlink is not treated as a new installation|PASS|PASS|一致|
|W68 edited runtime is preserved and writes a visible pending notice|PASS|PASS|一致|
|W68 empty marker is untrusted and leaves runtime unchanged|PASS|PASS|一致|
|W68 equal unmarked content hides the row without adopting ownership for a later update|PASS|PASS|一致|
|W68 explicit apply adopts an unmarked runtime only after private backup and records the bundled digest|PASS|PASS|一致|
|W68 failed backup aborts replacement and preserves the existing backup|PASS|PASS|一致|
|W68 failed manual replacement does not claim ownership of custom contents|PASS|PASS|一致|
|W68 line diff preserves context, repeated/empty lines and terminal newline changes|PASS|PASS|一致|
|W68 matching installed hash auto-updates runtime and marker, with exact preimage backup|PASS|PASS|一致|
|W68 missing marker never grants automatic ownership|PASS|PASS|一致|
|W68 native row click opens a sheet and both real buttons persist, dismiss and hide the row|PASS|PASS|一致|
|W68 native settings row exists only for pending differences; diff actions and Island are wired|PASS|PASS|一致|
|W68 native stale preview preserves external edits, refreshes the sheet and requires another decision|PASS|PASS|一致|
|W68 review actions cannot act on a changed bundled version after preview|PASS|PASS|一致|
|W68 review actions cannot act on an external runtime edit made after preview|PASS|PASS|一致|
|W68 runtime symlink backup retains actual preimage bytes when its target changes later|PASS|PASS|一致|
|W68 unmarked custom keep preserves bytes and keptUserEdited across model recreation|PASS|PASS|一致|
|W68 update completion uses the relaunched App bundle and not the old downloader resources|PASS|PASS|一致|
|W71 preview and confirmation share notices and never offer old constitution seeding|PASS|PASS|一致|
|W71 production binding: constitution-edited|PASS|PASS|一致|
|W71 production binding: existing-archive|PASS|PASS|一致|
|W71 production binding: existing-upstream|PASS|PASS|一致|
|W71 production binding: missing|PASS|PASS|一致|
|W71 production binding: missing-with-upstream|PASS|PASS|一致|
|W71 production binding: preserve|PASS|PASS|一致|
|W71 production binding: readonly|PASS|PASS|一致|
|W71 production binding: root-missing|PASS|PASS|一致|
|W71 production binding: stale|PASS|PASS|一致|
|W75 archives are byte-preserving moves and the active readers have migrated|PASS|PASS|一致|
|W75 authority detector covers case variants, nested archives and unapproved paths|PASS|PASS|一致|
|W75 production Swift loader projects v4 and rejects legacy, malformed or incomplete documents|PASS|PASS|一致|
|W75 public root retains the release train and both summaries defer to the entrance|PASS|PASS|一致|
|W75 public v4 template preserves §0–§11 and does not transfer private authorization|PASS|PASS|一致|
|W75 repository has no competing authority claims outside the requested historical exclusions|PASS|PASS|一致|
|W75 root pointers stay short, use the entrance and retire 1.0 role contracts|PASS|PASS|一致|
|W75 whitelist export and explicit public safety scan pass on a fresh TMPDIR fixture|PASS|PASS|一致|
|W76 production Swift: format|PASS|PASS|一致|
|W76 production Swift: guards|PASS|PASS|一致|
|W76 production Swift: migration|PASS|PASS|一致|
|W76 production Swift: pairing|PASS|PASS|一致|
|W76 production Swift: reader|PASS|PASS|一致|
|W76 production Swift: registry|PASS|PASS|一致|
|W76 production Swift: roles|PASS|PASS|一致|
|W76 wiring: production reader is fixture-free; pairing carries real IDs and epoch|PASS|PASS|一致|
|W77 bridge and UI wiring never mount the writing/placeholder path|PASS|PASS|一致|
|W77 production Swift: code|PASS|PASS|一致|
|W77 production Swift: diff|PASS|PASS|一致|
|W77 production Swift: offline|PASS|PASS|一致|
|W77 production Swift: policy|PASS|PASS|一致|
|W77 production Swift: reader|PASS|PASS|一致|
|W78 catalog routes A/E to one adapter and C to git, never entrance legacy files|PASS|PASS|一致|
|W78 dispatch replaces legacy system-pull for constitution, Skillet and global notes|PASS|PASS|一致|
|W78 production Swift: dual-root dispatch, signed RPC, documents, inbox and pull files|PASS|PASS|一致|
|W79 lock retries never repeat branch creation inside worktree add|PASS|PASS|一致|
|W79 production app: generation, two devices, ownership, binding readback and exact removal|PASS|PASS|一致|
|W79 retains the real BINDTEST and OSUPSTREAMREFRESHTEST contracts in isolated storage|PASS|PASS|一致|
|W79 three native injection points consume the composed runtime without changing vendor ownership|PASS|PASS|一致|
|W80b Grok registry selection reaches isolated MCP config and replaces quoted legacy GBrain|PASS|PASS|一致|
|W80b HTTP transport rejects non-loopback, TLS downgrade targets and credentials|PASS|PASS|一致|
|W80b SSH uses paired host trust, validates target/port and quotes remote wrapper arguments|PASS|PASS|一致|
|W80b UI guards secondary credentials and no-key semantic search; helper sign precedes app seal|PASS|PASS|一致|
|W80b actual PGLite: single owner, two stdio clients, metadata, denylist, secret scans before/after shutdown|SKIP|SKIP|一致|
|W80b actual asset is cached, verified, placed in Helpers and re-signed in a synthetic bundle|SKIP|SKIP|一致|
|W80b deny destructive, schema, generic SQL and unimplemented write routes|PASS|PASS|一致|
|W80b existing stdio service stays on its wrapper and never invokes the new helper|PASS|PASS|一致|
|W80b live service lock still blocks a second service|PASS|PASS|一致|
|W80b no inherited DB credentials; log redaction and recursive leak detection|PASS|PASS|一致|
|W80b official release digest matches pinned packager|SKIP|SKIP|一致|
|W80b production Swift: secondary cannot access provider credentials; no key cannot enable semantics|PASS|PASS|一致|
|W80b secondary refuses every local database mode before executing a helper|PASS|PASS|一致|
|W80b stale service lock from a dead owner is archived and reacquired|PASS|PASS|一致|
|W80b writes receive trusted device metadata; reads remain byte-equivalent|PASS|PASS|一致|
|W81 canvas contract after W180 E4: no skillet destination, no toggles, only the human confirm writes|PASS|PASS|一致|
|W81 production Swift: draft, repeated rewrite, exact edits, human boundary, cancel/reopen, guards (W180 E4 canvas)|PASS|PASS|一致|
|W81 real GBrain (W180 E4 production path): archive same-slug page whole → write → refuse changed page → restore old page + title|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W82 keeps installer copies byte-identical and first-run work in App|PASS|PASS|一致|
|W82 production onboarding: clean HOME, preview, identity, rules, exact removal and secondary isolation|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W83 a retained record addressed to another device grants nothing|PASS|PASS|一致|
|W83 new primary connects back only when the transfer kept GBrain on the former primary|PASS|PASS|一致|
|W83 primary owns a local brain by default and may not connect remotely|PASS|PASS|一致|
|W83 production transfer: signed dual-device roundtrip, interruption, four checkpoints and screenshot|PASS|PASS|一致|
|W86 registry durability and native drop/menu/click/scroll/theme candidates|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|W86 strip geometry, placement, ID-only drops and W66 identity are explicit|PASS|PASS|一致|
|W87a App preflight includes parts/joining in addition to staging before payload|PASS|PASS|一致|
|W87a actual installer receipt and App helper preserve all phases and original prefetch source|PASS|PASS|一致|
|W87a both installer copies and App keep checksum authority, phase handoff, and bounded ranges|PASS|PASS|一致|
|W87a installer reserves range peak on both volumes before requesting ZIPs|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession broken|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession cancellation does not leave an unverified final archive|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession corrupt|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession good|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession ignored|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession resume|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › URLSession small|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › both transports use the same default and invalid-override fallback|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › broken|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › corrupt|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › good|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › ignored|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › installer runtime reuse=false decides before any runtime HTTP request|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › installer runtime reuse=true decides before any runtime HTTP request|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › mirror|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › resume|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › small|PASS|PASS|一致|
|W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts › verified mirror is used without a GitHub payload request|PASS|PASS|一致|
|W87b changes no installer, packaging or signing gate|PASS|PASS|一致|
|W87b current gate guard still rejects signing changes outside conversation backups|PASS|PASS|一致|
|W87b production policy and schedule decisions compile and hold|PASS|PASS|一致|
|W87b-1 metered blocking is visible, switchable and overridable for one candidate|PASS|PASS|一致|
|W87b-2 a path change pauses instead of cancelling; cancellation stays user or superseded only|PASS|PASS|一致|
|W87b-2 paused transfers issue nothing, keep their parts and only refetch the missing ranges|PASS|PASS|一致|
|W87b-2 paused transfers issue nothing, keep their parts and only refetch the missing ranges › a paused transfer sends nothing, then finishes the same run|PASS|PASS|一致|
|W87b-2 paused transfers issue nothing, keep their parts and only refetch the missing ranges › the gate releases every waiter on resume and on cancellation|PASS|PASS|一致|
|W87b-2 paused transfers issue nothing, keep their parts and only refetch the missing ranges › 已下載的 parts 留著，恢復後只補缺的段|PASS|PASS|一致|
|W87b-3 six-hour monotonic schedule keeps the launch check and adds no background wake|PASS|PASS|一致|
|W89 Bot page 三段流 live 走同一條建立函式；fixture 維持展示文案|PASS|PASS|一致|
|W89 dead code removed: BotStore fixtureSeed/systemPrompt gone, live library reused|PASS|PASS|一致|
|W89 production Swift: empty workspace precondition picks owner, bot gate, project gate|PASS|PASS|一致|
|W89 production binary: from zero, a domain without a bot and one with a bot|PASS|PASS|一致|
|W89 settings › Space empty state is not an error and owns the only creation path|PASS|PASS|一致|
|W90 clean baseline empty state: empty library, registry and entrance render without red state|PASS|PASS|一致|
|W90 production sources never seed fixture data on the clean path|PASS|PASS|一致|
|W91 compiled production registry: upgrade, order, retirement, old-reader compatibility, strict alias pin|PASS|PASS|一致|
|W91 endpoint budget and UI use shared production paths; live script stays read-only|PASS|PASS|一致|
|W91b compiled pairing: both sides exchange both fingerprints over the existing channel|PASS|PASS|一致|
|W91b compiled registry: legacy split by direction, pins stay separate, fills never relax|PASS|PASS|一致|
|W91b wiring: each path reads only its own key, nothing loosens, no new pairing socket|PASS|PASS|一致|
|W91c 編譯：缺指紋的紀錄被拒，有指紋的產生 StrictHostKeyChecking=yes ＋ pin 檔|PASS|PASS|一致|
|W91c: immutable pin helpers unchanged; W187 authorized trust extension keeps strict checks|PASS|PASS|一致|
|W91c: 三處 ssh／rsync 只吃主機金鑰 pin，沒有放寬旋鈕|PASS|PASS|一致|
|W95 (a)(e) production Swift：kind 白名單、commit／tests 驗證、device_status.capacity|PASS|PASS|一致|
|W95 (b) 記憶體門檻不足：工作停在 queued，reason 非空，不留收據|PASS|PASS|一致|
|W95 (c) 兩個 build 工作序列化：第二個等第一個 done|PASS|PASS|一致|
|W95 (d) 收據欄位齊全、logTail ≤ 200、失敗帶 exit 與 reason|PASS|PASS|一致|
|W95 job_submit/job_status 只是 W78 通道上多一種 payload，沒有第二套驗證|PASS|PASS|一致|
|W95 runner 也擋白名單外的 kind 與不合法欄位，且只跑對應表裡的腳本|PASS|PASS|一致|
|W95 scripts/rooms：九支工具入庫、可執行、且沒有寫死的機器路徑|PASS|PASS|一致|
|W95 staging／系統碟門檻不足：同樣停在 queued 並寫原因|PASS|PASS|一致|
|W95 建置鎖被別人持有：工作停在 queued 並寫出持有者|PASS|PASS|一致|
|W96 App bundle 帶技能本體與 agents，不帶 references|PASS|PASS|一致|
|W96 App 打包公開技能的 SKILL.md 與 agents/，不帶 references/|PASS|PASS|一致|
|W96 clean-install-gate 有技能種檔斷言|PASS|PASS|一致|
|W96 公開匯出仍帶技能本體與 agents|PASS|PASS|一致|
|W96 受管檔機制是共用的，不是複製一份|PASS|PASS|一致|
|W96 種檔三態：全新安裝／未手改自動更新／手改保留|PASS|PASS|一致|
|W96 設定 › Plugin 顯示 App 內建（受管）／已手改（保留）|PASS|PASS|一致|
|W97 (a) force-renderer-accessibility is only appended inside the gate|PASS|PASS|一致|
|W97 (b) SetAccessibilityState(STATE_ENABLED) is only called inside the gate|PASS|PASS|一致|
|W97 (c) the pump and windowed-rendering settings are untouched|PASS|PASS|一致|
|W97 (d) our --disable-features entries are unchanged; CEF's own protection list is restated after them|PASS|PASS|一致|
|W97 diagnostics reports the tree state and the reason it was decided|PASS|PASS|一致|
|W97b (a) without CEF_PGO the build is the W94 one, word for word|PASS|PASS|一致|
|W97b (b) CEF_PGO=1 turns on phase 2 and changes nothing else|PASS|PASS|一致|
|W97b (c) CEF_PGO=1 also fetches the profiles, or ninja stops mid-build|PASS|PASS|一致|
|W97b (d) the PGO archive gets its own name, beside the one in use|PASS|PASS|一致|
|W97b (e) the distribution directory inside the archive keeps the pinned name|PASS|PASS|一致|
|W97b (f) the official-dylib replacement still runs, from archive or directory|PASS|PASS|一致|
|W98 UI 檔不碰私鑰|PASS|PASS|一致|
|W98 信任那幾檔零改動；DeviceRegistry 只動 fingerprintSummary 的字|PASS|PASS|一致|
|W98 文案：端點三種路白話、順序說明一行、指紋改隧道／簽章識別|PASS|PASS|一致|
|W98c 專案是自己的可展開列，討論串只在專案展開後才列|PASS|PASS|一致|
|W98d 側欄：每台設備一個跟「專案」「聊天」同層的區塊，標題照專案區那顆|PASS|PASS|一致|
|W99 ceiling constant is 2 GB and the management page reuses the same constant|PASS|PASS|一致|
|W99 enforce clears rebuildable caches of the current profile before failing closed|PASS|PASS|一致|
|W99 fail-closed message is plain Chinese and keeps the raw error for diagnosis|PASS|PASS|一致|
|W99 management page shows current profile size and the last cache eviction|PASS|PASS|一致|
|XFER-04 committed missing participants expire and can be skipped physically|PASS|PASS|一致|
|a ChatGPT model chosen while it is still starting is kept, and the list survives the wake|PASS|PASS|一致|
|a new durable writer file fails closed even when catalog lists stay unchanged|PASS|PASS|一致|
|a new room script is not silently covered by its reviewed neighbours|PASS|PASS|一致|
|a new write site inside a classified file invalidates the reviewed fingerprint|PASS|PASS|一致|
|a realistic-size PNG reaches the child intact without base64 argv or retained temp files|PASS|PASS|一致|
|a source symlink cannot pull an external file into the package|PASS|PASS|一致|
|a symlinked source subdirectory is rejected before any output|PASS|PASS|一致|
|absent consumer readback does not silently pass|PASS|PASS|一致|
|acceptEdits preserves its existing SDK options, MCP wiring and host approval callback|PASS|PASS|一致|
|account A to B and back to A while connectorDelete waits still voids the deletion|PASS|PASS|一致|
|account actions live in one ellipsis menu and preserve default-account switching|PASS|PASS|一致|
|account removal requires a cancellable confirmation, not the menu click|PASS|PASS|一致|
|active stop clears queue; late old events cannot terminate the next turn|PASS|PASS|一致|
|active-looking target head without matching device receipt is excluded fail-closed|PASS|PASS|一致|
|activity helper retains edits and playback without reading form values|PASS|PASS|一致|
|activity reducer stores the video flag per frame; old callers leave it false|PASS|PASS|一致|
|activity script: the fourth flag is a playing, sized, laid-out <video> — never its source or the page|PASS|PASS|一致|
|actual Browser settings builder orders cards and reads the observed registry|PASS|PASS|一致|
|actual Coder mode card is TAP-aware, greys every TAP option and explains why|PASS|PASS|一致|
|actual Swift registry + Island: fixture detection, dedupe, persistence and user-approved open|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|actual browser navigation row renders without squeezing out the address field|SKIP|SKIP|一致|
|actual build-app plist heredoc registers browser schemes and HTML/URL Viewer types|PASS|PASS|一致|
|actual create_project validation rejects controls and newlines before trimming|PASS|PASS|一致|
|actual permission presets honor full access and explicit narrower scopes|PASS|PASS|一致|
|actual popup AppKit controller retains CEF, routes search-field keys, restores focus and preserves fullscreen geometry|PASS|PASS|一致|
|actual snapshot function identifies unlabelled native and role buttons from visible children|PASS|PASS|一致|
|actual tab host and close aggregation with controlled native callbacks|SKIP|SKIP|一致|
|ad-hoc re-sign cannot hide main or nested-content replacement while helper and Info.plist stay unchanged|PASS|PASS|一致|
|ad-hoc reuse fails closed before an unapproved signing migration|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|address pill follows the real page; not https or wrong domain is flagged; device chip; back/forward; float card under ChatGPT tabs|PASS|PASS|一致|
|admission has no staging write outside atomic GoalAuthorityTransaction|PASS|PASS|一致|
|all four new categories enforce exact file + regex and every value on a line|PASS|PASS|一致|
|all scoped root consumers delegate; UI hides editor on read failure and exposes real paths|PASS|PASS|一致|
|all shipped App resource readers avoid SwiftPM fatal build-path fallback|PASS|PASS|一致|
|all three TAP send entries enforce the shared refusal before side effects|PASS|PASS|一致|
|already completed turn is not interrupted or revived by its late start reply|PASS|PASS|一致|
|ambient PATH node shim cannot enter the provenance root of trust|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|an empty required source is rejected before any output|PASS|PASS|一致|
|an existing destination is preserved, never merged with stale contents|PASS|PASS|一致|
|an existing staging runtime can pin its previously issued anchor identity|PASS|PASS|一致|
|anti-smuggle matchers reject real controls and SDK imports, not helper names or system imports|PASS|PASS|一致|
|apply and rollback reject fake-HOME ~/.codex targets without explicit acknowledgement|PASS|PASS|一致|
|apply failure plus automatic-restore failure is explicit and authority-bound|PASS|PASS|一致|
|apply overwrite is refused|PASS|PASS|一致|
|approval prose cannot mint authorization|PASS|PASS|一致|
|approved text, external-only cards, conditional volume and brand controls|PASS|PASS|一致|
|archive first, 還原.md, manifest saved before every change; restore keeps memory/|PASS|PASS|一致|
|archive tamper fails closed against the durable snapshot digest binding|PASS|PASS|一致|
|archives never carry AppleDouble sidecars and the installer extracts with ditto|PASS|PASS|一致|
|ask-first refuses before spawning Grok; approve-for-me and full access run with --always-approve|PASS|PASS|一致|
|assistant has durable dedicated identity and sidecar-level persona, not selection-based injection|PASS|PASS|一致|
|assistant manual describes session distillation as reusable skills or other material|PASS|PASS|一致|
|assistant model menu is the Coder glass chip with friendly names and disabled engines marked|PASS|PASS|一致|
|assistant sends to explicit local ID and all Coder lists exclude the project|PASS|PASS|一致|
|assistant tools: project_overview is metadata only; project_suggest only queues and only from the assistant|PASS|PASS|一致|
|async replies (image generation) are awaited before reporting no reply|PASS|PASS|一致|
|atomic directory exchange never removes either visible path|PASS|PASS|一致|
|attached card follows the display item containing its source, including folded timelines|PASS|PASS|一致|
|attachment busy hydration can take longer than five seconds, still one bounded send|PASS|PASS|一致|
|attachment-only blank text is allowed, text-only whitespace is rejected|PASS|PASS|一致|
|audit is durable before execution, one bounded file per call, no dropped or truncated history|PASS|PASS|一致|
|authority readback uses the sole canonical V3 resolver call|PASS|PASS|一致|
|authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants|PASS|PASS|一致|
|authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants › cross-goal replay|PASS|PASS|一致|
|authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants › cross-operational-plan replay|PASS|PASS|一致|
|authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants › expired grant|PASS|PASS|一致|
|authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants › overlong grant|PASS|PASS|一致|
|authorized fake-root apply backs up, reads back, and preserves unmanaged files|PASS|PASS|一致|
|autonomous turn before Goal notification and late old start reply retains native identity|PASS|PASS|一致|
|availability published by App launch; display only; installer and signature gate unchanged|PASS|PASS|一致|
|background alpha and text opacity both affect contrast while opaque dark CSS is retained|PASS|PASS|一致|
|backup uses UTC sortable filename and saves exclusive preimage bytes before replacement|PASS|PASS|一致|
|backups retain the oldest preimage after more than twenty saves|PASS|PASS|一致|
|bare or damaged repositories cannot fall back to an ordinary room|PASS|PASS|一致|
|behavioral acceptance registered and isolated|PASS|PASS|一致|
|blocked Goal is not resumed by ordinary chat or turn completion|PASS|PASS|一致|
|bookmarks / favorites / typing open a NEW general tab — never navigate the Pod, pairing or authorisation tabs|PASS|PASS|一致|
|bookmarks, favorites, spaces are read from the main window's Browser space — read and open only; switching = the sidebar dot|PASS|PASS|一致|
|bootstrap recovery plan is explicitly untrusted until fresh root-admin review|PASS|PASS|一致|
|borrowed target cannot migrate data, fall back to workspace, or retain stale commands/find|PASS|PASS|一致|
|both headers use one kind title function, including feedback and PR|PASS|PASS|一致|
|both human and injected rules preserve lightweight, direct execution and safety|PASS|PASS|一致|
|both packaging entrypoints invoke the same explicit source staging|PASS|PASS|一致|
|both scripts parse; diagnostics name common affected sites|PASS|PASS|一致|
|both sheet entries, five metrics-based cards, task cancellation and backend-only telemetry|PASS|PASS|一致|
|both sidecars forward an imported MCP and its current env without secret argv|PASS|PASS|一致|
|both starts resolve before asking, gate monitors, and keep TCC checks|PASS|PASS|一致|
|bottom space switcher cannot stretch vertically and float above the footer|PASS|PASS|一致|
|bounded pending: DOM, URL, poll, side SSE and wrapped WS cannot contaminate unjoined or revoked first turn|PASS|PASS|一致|
|bounded pending: HTTP/fetch failure or cancellation before acceptance cannot revive via late original bytes|PASS|PASS|一致|
|bounded pending: Navigation type uses the captured native getter, never a rewritten getter or plain object|PASS|PASS|一致|
|bounded pending: an already in-flight root poll cannot publish after entering quarantine or revocation|PASS|PASS|一致|
|bounded pending: arbitrary/wrong-length/encoded/trailing routes remain denied by the real guard|PASS|PASS|一致|
|bounded pending: canonical URL, poll completion or unrelated SSE cannot supply the original ID|PASS|PASS|一致|
|bounded pending: canonical must be the entire path and exactly match the original SSE ID|PASS|PASS|一致|
|bounded pending: completed candidate retains exact per-command consent and original body guards|PASS|PASS|一致|
|bounded pending: different local/canonical, root return, mode reversal, cancel or origin change permanently revoke|PASS|PASS|一致|
|bounded pending: direct non-local /g/.../c path retains the pre-existing behavior|PASS|PASS|一致|
|bounded pending: eligibility requires the same live initial turn, root origin and real send dispatch|PASS|PASS|一致|
|bounded pending: equivalent decoded prefix is still a second raw route and permanently revokes|PASS|PASS|一致|
|bounded pending: exact 52-character unencoded ASCII-pchar prefix/UUID shape is not identity; diagnostics contain no prefix|PASS|PASS|一致|
|bounded pending: finish-time route/origin/cancel/failure cannot complete or dereference a revoked proof|PASS|PASS|一致|
|bounded pending: forbidden/malformed/double-encoded prefixes revoke without content pollution or late revival|PASS|PASS|一致|
|bounded pending: former similar-prefix counterexamples now only qualify as quarantined shapes, not proof|PASS|PASS|一致|
|bounded pending: joined side-stream completion before original ends revokes; late original cannot revive|PASS|PASS|一致|
|bounded pending: local pending finish cannot complete even with original ID; late canonical cannot revive it|PASS|PASS|一致|
|bounded pending: normal/unknown/no-consent and invalid native body cannot borrow a proof|PASS|PASS|一致|
|bounded pending: original ID plus canonical, message_stream_complete then read-error retains poll completion|PASS|PASS|一致|
|bounded pending: original SSE ID before/after canonical works only after first-turn completion|PASS|PASS|一致|
|bounded pending: original read-error before identity intersection revokes and late bytes/route cannot revive|PASS|PASS|一致|
|bounded pending: pchar classification is exact over ASCII and prefix diagnostics are booleans only|PASS|PASS|一致|
|bounded pending: pending is possible before HTTP acceptance but ID binding is not|PASS|PASS|一致|
|bounded pending: percent tokenizer accepts only ASCII pchar bytes, never decoded-length or UUID-boundary repair|PASS|PASS|一致|
|bounded pending: popstate, traverse/reload/unknown Navigation type revoke even at identical pathname|PASS|PASS|一致|
|bounded pending: raw and percent-token pchar prefixes stay isolated until original ID and exact canonical intersect|PASS|PASS|一致|
|bounded pending: repeated identical path notifications are allowed, not a second local ID|PASS|PASS|一致|
|bounded pending: send/edit/regenerate remain denied at both unjoined and joined-but-unfinished stages|PASS|PASS|一致|
|box copy and structure follow the mock: target icons, session picker, approvals, hints, glass not blue|PASS|PASS|一致|
|branch collision rejects instead of returning an uncreated worktree|PASS|PASS|一致|
|bridge actors gate downloads, permissions, all resource entry points and context sharing|PASS|PASS|一致|
|bridge: one more boolean (a visible <video> is playing), only for the human page, with defaults so old callers compile|PASS|PASS|一致|
|bridge: tools on no trust list; paired devices decide by id only; engines cannot decide|PASS|PASS|一致|
|broad physical disconnect clearly names the affected device scope|PASS|PASS|一致|
|broken governed source symlinks fail closed|PASS|PASS|一致|
|browser bridge recovers dead endpoints while preserving active listeners|PASS|PASS|一致|
|browser rejoins the shared chat sidebar shell and footer with no private shell|PASS|PASS|一致|
|browser visibility is opt-in and the default controller fallback stays three modes|PASS|PASS|一致|
|build prepares the sealed manifest after nested signing and before outer signing; release keeps full ZIP|PASS|PASS|一致|
|build-output drift fails closed against its captured filesystem manifest|PASS|PASS|一致|
|builder refuses a system-disk output even in plan mode|PASS|PASS|一致|
|built Tatwo2 observes an isolated skills root appearing after the initial scan|PASS|PASS|一致|
|built-in device is TATWO clean-room source using Apple frameworks only|PASS|PASS|一致|
|bundle content manifest fails closed for resource, helper, and nested-code drift|PASS|PASS|一致|
|bundle content manifest fails closed when only the main executable changes|PASS|PASS|一致|
|bundle content manifest is deterministic across Info, provenance, manifest, and code-signature changes|PASS|PASS|一致|
|bundle identity enforces CandidateID, embedded source/build manifests, and embedded provenance pins|PASS|PASS|一致|
|bundle identity rejects installed embedded provenance drift|PASS|PASS|一致|
|bundle-relative scanner works without repository scripts; packaging requires and copies it|PASS|PASS|一致|
|busy then ready: waits for hydration without removing disabled and clicks exactly once|PASS|PASS|一致|
|bypassPermissions preserves its existing SDK options, MCP wiring and host approval callback|PASS|PASS|一致|
|byte-identical plan produces a human-bound noop receipt without rewriting targets|PASS|PASS|一致|
|callers moved to the Browser: HandsSetup login page, secondary auto-open, R6b Pod and pairing page; ［連線］ card stays native|PASS|PASS|一致|
|cancel during busy wait or immediately before click never clicks or emits retryable failure|PASS|PASS|一致|
|cancel voids window, pending transaction and unredeemed codes; revokes the attempt grant; closeWindow also drops unredeemed codes|PASS|PASS|一致|
|candidate filter: never lend auth pages, Pod, pairing/login popups, AI tabs or AI control, sensitive or https-only pages, non-human, sleeping or chat session tabs|PASS|PASS|一致|
|canonical registry validates exact native preset routing|PASS|PASS|一致|
|canonical-source-unavailable receipt keeps source and fallback authorization failures visible|PASS|PASS|一致|
|canvas retains issue URL, isolates draft ownership and exposes in-place GH device login|PASS|PASS|一致|
|cards: priority, and the pairing card reads only the expiry (the code never reaches the tent)|PASS|PASS|一致|
|catalog cannot hide a durable surface by deleting both internal declarations|PASS|PASS|一致|
|catalog cannot invent an entry absent from the durable inventory|PASS|PASS|一致|
|cataloged writer policy cannot reference an unknown sync surface|PASS|PASS|一致|
|cataloged writer policy must bind a shared or device-overlay surface|PASS|PASS|一致|
|centered search focus does not open the separate address popup|PASS|PASS|一致|
|changed resource, mode, entitlement, corrupt seal and wrong identity do not reuse bundle|PASS|PASS|一致|
|chat plus menu connects through existing controller without a settings round trip|PASS|PASS|一致|
|check completion timestamps success and failure, clears busy, and deduplicates in-flight checks|PASS|PASS|一致|
|checked-in project parses and targets iPad in both build configurations|PASS|PASS|一致|
|clean version-push pushes existing HEAD only to dev/device|PASS|PASS|一致|
|cleanup deletes a same-URL numbered duplicate, never the active connector or another URL|PASS|PASS|一致|
|clearing is archive-not-delete: the device folder goes to the Trash (restorable); self-test never touches the real Trash|PASS|PASS|一致|
|click throwing is still unknown, never marked not-submitted|PASS|PASS|一致|
|close retains the prompt until the native child exits, then cleans it|PASS|PASS|一致|
|closed-world build input manifest deterministically binds Swift and native helper sources, flags, toolchain, SDK, architecture, dependency, and sanitized environment identity|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|closed-world native helper source rejects a symlink to ambient bytes|PASS|PASS|一致|
|closed-world toolchain identity ignores ambient PATH shims|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|closing the delete dialog is not success while the connector still appears in the complete list|PASS|PASS|一致|
|closing the inspector retains the card and the existing open actions|PASS|PASS|一致|
|cloudflared: only the pinned download verified by sha256 (archive and binary), never Homebrew, never auto-updated|PASS|PASS|一致|
|codesign really rejects the bare form and accepts the = form (Apple-signed /usr/bin/true)|PASS|PASS|一致|
|collapse orders the main window out without the close confirmation or an activation-policy change|PASS|PASS|一致|
|collapsed Browser unmounts the entire rail, not a narrow empty Browser column|PASS|PASS|一致|
|collapsed Browser uses the shared edge overlay without reserving canvas width|PASS|PASS|一致|
|collapsed sidebar restore and menu use the same explicit toggle|PASS|PASS|一致|
|commit failure reports saved-but-uncommitted without losing the new text or preimage|PASS|PASS|一致|
|common Python durable writer primitives are discovered|PASS|PASS|一致|
|common append, deletion, metadata, and in-place writer primitives are discovered|PASS|PASS|一致|
|compensating activation is reported distinctly from an atomic swap|PASS|PASS|一致|
|compiled W225a2 regressions use isolated fake conversations and project folders|PASS|PASS|一致|
|compiled W225a3 regressions use isolated fake conversations and project folders|PASS|PASS|一致|
|compiled shared policy denies every marked managed TAP thread, preserves other routes|PASS|PASS|一致|
|compiled w185tools executable selftest (isolated fake UI, real Hands/auth/journal/epoch)|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|complete local evidence yields layered pass without cross-machine borrowing claim|PASS|PASS|一致|
|completed work does not receive recovery chatter|PASS|PASS|一致|
|completion before start response cannot resurrect a turn or block the queue|PASS|PASS|一致|
|composedSystemPrompt testing wrapper is available only in DEBUG|PASS|PASS|一致|
|composer detached by the first insert is never reused on the bounded insertion retry|PASS|PASS|一致|
|composer replacement while waiting can only send if current text still matches|PASS|PASS|一致|
|config.toml: minimal edits (generate_memories=false, [features] memories=true); use_memories untouched|PASS|PASS|一致|
|confirm is explicit, waits for start, and persists one-shot consumption|PASS|PASS|一致|
|conflicting source-name and repository-ID directories fail closed|PASS|PASS|一致|
|connector diagnostics exclude hidden/sidebar conversations and refuse to dump a chat page or ambiguous surface|PASS|PASS|一致|
|constitution/skillet commit in the entry repo; runtime upstream only backs up|PASS|PASS|一致|
|consumer cannot local-unify skillet.md|PASS|PASS|一致|
|consumer environment cannot unify into its own live files|PASS|PASS|一致|
|consumer loaded digest outside active store set fails closed|PASS|PASS|一致|
|contenteditable composer uses an in-box range and verifies innerText|PASS|PASS|一致|
|continuation: cancellation/navigation/mode changes during Blob or Request decoding cannot dispatch or renew proof|PASS|PASS|一致|
|continuation: every original send must contain exact native true/false, before rewriting|PASS|PASS|一致|
|continuation: excluded elements and unrelated attributes cannot revoke native proof|PASS|PASS|一致|
|continuation: initial rewritten flags and URL/DOM completion never mint genuine proof|PASS|PASS|一致|
|continuation: leaving and returning to same route permanently revokes proof|PASS|PASS|一致|
|continuation: missing picker uses genuine original-flags + server-ID proof, not URL alone|PASS|PASS|一致|
|continuation: observed mode reversal revokes proof even when the picker vanishes again|PASS|PASS|一致|
|continuation: off/unpersonalized/ambiguous native controls contradict missing-picker proof|PASS|PASS|一致|
|continuation: original prepare flags are checked too, even without a model rewrite|PASS|PASS|一致|
|continuation: reload loses proof even with matching URL and explicit consent|PASS|PASS|一致|
|continuation: same ID without explicit per-command consent cannot use old proof|PASS|PASS|一致|
|continuation: valid decoded Blob/Request bodies still work and cannot borrow another origin|PASS|PASS|一致|
|continuation: wrong command ID, original body ID or contradictory route fail closed|PASS|PASS|一致|
|continuity check passes the designated requirement as inline text, not a file path|PASS|PASS|一致|
|contract pins lock metadata, jobs, atomic commit, rollback roles, and never opens reuse|PASS|PASS|一致|
|control contract rejects a third Toggle and side effects hidden in approved setters|PASS|PASS|一致|
|controller discovers signing locally and reuses the exact Xcode certificate|PASS|PASS|一致|
|conversation scroll view is rebuilt per conversation / new chat|PASS|PASS|一致|
|copied DDC adaptation includes upstream full license and copyright|PASS|PASS|一致|
|copy remains on this Mac, clears only its own contents, and never submits|PASS|PASS|一致|
|copy revalidates current phase, card, visible surface, expiry and host code alphabet|PASS|PASS|一致|
|counts every hit beyond 200; definitions have priority; tests use even hidden Swift hits|PASS|PASS|一致|
|crash recovery can only stop a locally-owned previous service, never restore consent|PASS|PASS|一致|
|create_project describes shared folders and the Git requirement for workspaces|PASS|PASS|一致|
|create_project exposed with schema and dispatch|PASS|PASS|一致|
|creates a unique run directory when the sandbox parent does not exist|PASS|PASS|一致|
|data-sync selftest-merge unions concurrent host and secondary edits|PASS|PASS|一致|
|dedicated browser keeps window-responder shortcuts without capturing embedded chat focus|PASS|PASS|一致|
|default audit derives the durable local device identity|PASS|PASS|一致|
|default audit fails closed when local identity is unavailable|PASS|PASS|一致|
|default model skips disabled engines on the device that runs the assistant|PASS|PASS|一致|
|default preserves its existing SDK options, MCP wiring and host approval callback|PASS|PASS|一致|
|default source root is App Support/skills, not an external volume|PASS|PASS|一致|
|delegate forwarding, cold-launch replay and mounted-only delivery use the real inbox|PASS|PASS|一致|
|deleted parent is not recreated for pressure notification|PASS|PASS|一致|
|denied private navigation reloads its exact target through normal policy, never a stale or agent target|PASS|PASS|一致|
|dependency state rejects a checkout revision mismatch|PASS|PASS|一致|
|dependency state rejects an undeclared SwiftPM checkout|PASS|PASS|一致|
|derived local identity never accepts another device readback|PASS|PASS|一致|
|desk bubble sits one level above the floating box; the box opens beside it|PASS|PASS|一致|
|desk bubble: 44pt, every Space and full-screen app, draggable, remembered, default bottom-right inset 24|PASS|PASS|一致|
|detached composer after focus is re-resolved before any insertion|PASS|PASS|一致|
|detached target during focus does not receive text|PASS|PASS|一致|
|deterministic manifest, disjoint archives and a sealed reassembly (real ditto/codesign)|PASS|PASS|一致|
|device consent is app-neutral and neither host nor device force-opens Procreate|PASS|PASS|一致|
|diagnostic: capped counts, strict booleans and enums only; no raw metadata|PASS|PASS|一致|
|different staging runtime roots receive different PLG anchor identities|PASS|PASS|一致|
|direct keys: default ⌥⌘G = ChatGPT, blocked list with plain reasons, conflicts and occupied keys explained|PASS|PASS|一致|
|direct production writer calls remain in the canonical transaction only|PASS|PASS|一致|
|direct target TOML symlinks fail closed in plan, apply, and rollback|PASS|PASS|一致|
|direct target TOML symlinks fail closed in plan, apply, and rollback › apply rejects a target symlink introduced after planning|PASS|PASS|一致|
|direct target TOML symlinks fail closed in plan, apply, and rollback › plan rejects an individual target symlink|PASS|PASS|一致|
|direct target TOML symlinks fail closed in plan, apply, and rollback › rollback rejects a target symlink introduced after apply|PASS|PASS|一致|
|dirty provenance uses an isolated index, includes untracked source, and excludes ignored output|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|dirty source or source drift does not produce acceptance results|PASS|PASS|一致|
|dirty version-push refuses mixed; HEAD/index/worktree/branch unchanged|PASS|PASS|一致|
|dirty version-push refuses staged; HEAD/index/worktree/branch unchanged|PASS|PASS|一致|
|dirty version-push refuses unstaged; HEAD/index/worktree/branch unchanged|PASS|PASS|一致|
|dirty version-push refuses untracked; HEAD/index/worktree/branch unchanged|PASS|PASS|一致|
|disabled, read-only, noneditable, hidden and detached composers are not selected|PASS|PASS|一致|
|display copy distinguishes work space and bot space without renaming routing keys|PASS|PASS|一致|
|display section follows devices and preserves existing settings order and raw values|PASS|PASS|一致|
|docked child panel follows the main window at the same bottom-right spot on every Space|PASS|PASS|一致|
|docs: contract pairing section and T15 describe the attempt flow|PASS|PASS|一致|
|docs: contract §3b, threat-model T15, spec and tasks carry R10 and say which old rules it replaces (with the user's words)|PASS|PASS|一致|
|dry-run preserves external runtime HOME and pinned fixed signing identity|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|dry-run signing selection falls back to stable Apple Development without hardened runtime|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|dry-run signing selection prefers Developer ID over Apple Development|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|durable dirty-source payload independently reconstructs source_tree and preserves real index bytes|PASS|PASS|一致|
|durable writer fingerprint uses locale-independent codepoint ordering|PASS|PASS|一致|
|editable subtree text cannot be used as a parent control caption|PASS|PASS|一致|
|editor shares heading parser; persistence uses live store root and atomic JSON|PASS|PASS|一致|
|empty inbox leaves host files untouched|PASS|PASS|一致|
|engine deployment shares tested hashing gate and rsync checksums bytes|PASS|PASS|一致|
|engine-disable settings are never written by W179 F code|PASS|PASS|一致|
|engine-disable settings are never written by W182 R5 code|PASS|PASS|一致|
|engine: moveThread only changes project membership, sub-threads follow, one checked save|PASS|PASS|一致|
|entry DMBrowser: open(url:purpose:), openPod(purpose:), close(purpose:), markDone(purpose:); flow pages only from their flows (W184 G2: typing only opens new general tabs)|PASS|PASS|一致|
|ephemeral and verification-artifact writer policies cannot claim sync surfaces|PASS|PASS|一致|
|errors in plain Chinese: real unknown error and fetch/push directions|PASS|PASS|一致|
|every model-selection entry point lets a sleeping ChatGPT model through and wakes it|PASS|PASS|一致|
|every newly reviewed writer fails closed when its policy is removed or its writes change|PASS|PASS|一致|
|every skillet consumer requires a loaded digest from the active store set|PASS|PASS|一致|
|every source refresh failure call immediately returns 1|PASS|PASS|一致|
|every transferable feature has an explicit active or deferred system-pull decision|PASS|PASS|一致|
|exact native function replaces a later field without reading its value|PASS|PASS|一致|
|exact reset: blocked entry clears stale diagnostics; scan errors remain unknown and never click|PASS|PASS|一致|
|exact reset: duplicate fallback, anchor ambiguity and legacy/role-only conflicts all refuse clicks|PASS|PASS|一致|
|exact reset: exact label rejects suffix, prefix, case and invisible spoofing; ARIA takes precedence|PASS|PASS|一致|
|exact reset: existing visibility/enabled/message/form/dialog exclusions still apply|PASS|PASS|一致|
|exact reset: fallback cannot confirm no-op, wrong mode, retained messages, restored draft or changed origin|PASS|PASS|一致|
|exact reset: role-only semantics are observable but never a fallback|PASS|PASS|一致|
|exact reset: unique native BUTTON fallback clicks once and must confirm reset|PASS|PASS|一致|
|exact reset: zero/duplicate controls fail closed; single existing candidate clicks once|PASS|PASS|一致|
|exact, nested, and symlink-aliased source/runtime roots fail closed|PASS|PASS|一致|
|executable Swift checks cover feedback parse, migration, environment and command dispatch|PASS|PASS|一致|
|executable checks cover fences, fake multi-file diff, persistence and command dispatch|PASS|PASS|一致|
|executable self-test covers sizes, blocked keys, key storage, bubble position and the collapse machine|PASS|PASS|一致|
|executable self-test covers the brief|PASS|PASS|一致|
|executable self-test w184button covers the brief|PASS|PASS|一致|
|executable self-test w184chat covers the brief (rules, drawn positions, identifiers, PNG evidence)|PASS|PASS|一致|
|executable self-test w184forms covers the brief|PASS|PASS|一致|
|executable self-test w184tent covers the brief|PASS|PASS|一致|
|existing build lock remains owned by the other job|PASS|PASS|一致|
|existing worktree directory and user content remain untouched on failure|PASS|PASS|一致|
|expiry, local stop, revocation and cross-grant isolation use existing native epoch gate|PASS|PASS|一致|
|explicit Node override fails closed without executing it|PASS|PASS|一致|
|explicit ad-hoc to fixed identity migration reports one-time TCC reauthorization|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|explicit current-root override retargets a stale reuse plist without changing the fixed slot|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|explicit migration upgrades an unpinned legacy receipt to Chromium|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|explicit retirement tombstone archives a stale repository atomically|PASS|PASS|一致|
|explicit second Stop interrupts a turn even while Goal query is hanging|PASS|PASS|一致|
|explicit send reuses existing submit with card title and remaining Markdown; attempts cannot replay|PASS|PASS|一致|
|explicit toggle unpins before collapsing; passive collapse still respects pinning|PASS|PASS|一致|
|external project added on another device is returned by the real Pod catalog script|PASS|PASS|一致|
|extra permission requests ask the App unless the thread has full access|PASS|PASS|一致|
|failed build never executes tests using an existing stale product|PASS|PASS|一致|
|failed insertion leaving blank is explicit not-submitted even when execCommand returns true|PASS|PASS|一致|
|failed sequential refresh never partially mutates the active store|PASS|PASS|一致|
|failure line sits outside the scroll area, above the composer|PASS|PASS|一致|
|failure reopens only a stopped App and exits zero even if launchctl removal fails|PASS|PASS|一致|
|fake installed-extension icons are absent; blocked execution is explicit|PASS|PASS|一致|
|fatal missing-alias receipt preserves local attempt binding and a failed source row|PASS|PASS|一致|
|fatal receipt redacts governed registry CLI receipt and home paths|PASS|PASS|一致|
|feedback is presentation only and preserves caller-owned text|PASS|PASS|一致|
|feedback service enforces review and preserves uncertain drafts (no real model or POST)|PASS|PASS|一致|
|field counts and Unicode labels are bounded without breaking JSON|PASS|PASS|一致|
|filesystem creation errors are propagated, not reported as success|PASS|PASS|一致|
|finalize signs and verifies the prepared helper, but rejects pre-sign tampering|PASS|PASS|一致|
|five headings and optional Codable review preserve legacy artifacts|PASS|PASS|一致|
|five real paths; list/read never seed missing files or runtime upstream|PASS|PASS|一致|
|fixture guard rejects writable scratch even when its path is inside the allowlist|PASS|PASS|一致|
|fixture ids all use the fixture- prefix|PASS|PASS|一致|
|fixture refuses an explicitly pinned scratch root inside the production checkout before creating anything|PASS|PASS|一致|
|fixtures http_mapping：/mcp 沒 token 的 401 與 WWW-Authenticate 跟 fixture 一樣；錯 token 帶 invalid_token；OAuth 錯誤是 {error, error_description}|PASS|PASS|一致|
|fixtures 錯誤分三種：hands_call 的 unauthorized → 401、request_id_conflict／tool_not_allowed → 工具錯誤、os.sock 忙 → 暫時不能用；tools/list 撤銷 → 401；SSE 中途撤銷 → -32001|PASS|PASS|一致|
|fixtures/wire.json 形狀一致：關口送出的每一種請求欄位＝fixture；App 照 fixture 回，關口照樣接得住並轉成對的 HTTP 回應|PASS|PASS|一致|
|fixtures/wire.json: every hands_auth op, param, result key and error code has an App counterpart|PASS|PASS|一致|
|fleet agent queue preserves target authorization and reloads sealed readiness|PASS|PASS|一致|
|flow: window only after the user pressed; Pod checks (login, developer mode, existing connector) run with the window closed; no auto-resume|PASS|PASS|一致|
|focus and find lifecycle cover the persistent toolbar, not only the detachable page|PASS|PASS|一致|
|focus handler cannot change field to password then receive text|PASS|PASS|一致|
|focus redirection cannot send text into another field or App|PASS|PASS|一致|
|folder section uses plain language, supports folder drops, and retains removable rows|PASS|PASS|一致|
|follow-up in a conversation proceeds once the URL and composer are right, even if messages render late|PASS|PASS|一致|
|footer has the exact two requested secondary-text lines|PASS|PASS|一致|
|forced ad-hoc dry-run cannot select or execute the Developer ID signing path|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|form submission is explicit and invoked once|PASS|PASS|一致|
|formal authority begin and durable evidence preserve the typed owner kind|PASS|PASS|一致|
|formal local installer builds and verifies the same pinned CEF bundle contract as staging|PASS|PASS|一致|
|formless composer refuses other-form buttons and generic unrelated submit|PASS|PASS|一致|
|four forms (W184 AB), proportional shrink to fit, remembered (old sizes mapped); docked and floating boxes follow the form|PASS|PASS|一致|
|four layers: OS core and browser core know nothing about ChatGPT|PASS|PASS|一致|
|four normal outcomes and a non-throwing failure outcome exist|PASS|PASS|一致|
|fresh unmanaged target-id TOML is a conflict and is never adopted|PASS|PASS|一致|
|fsop.mjs R1b: secret lines masked with whole-file context; search never matches them; rollback is verified and never claims nothing changed|PASS|PASS|一致|
|fsop.mjs apply_patch: update, add, delete, move; context must match; all-or-nothing even when a write fails midway|PASS|PASS|一致|
|fsop.mjs read/list/search: line numbers, sha256, fixed order, cursor, complete, path:line:col with context|PASS|PASS|一致|
|fsop.mjs writes: protected at any depth and case, optimistic locks, symlinks and hard links refused, atomic|PASS|PASS|一致|
|full access grants extra permissions without asking|PASS|PASS|一致|
|full runner resolves the current SwiftPM product and enables native acceptance|PASS|PASS|一致|
|full-suite failure remains nonzero rather than the final echo masking it|PASS|PASS|一致|
|gateway cache uses elapsed time but IP-list expiry still uses wall time|PASS|PASS|一致|
|gateway label discovery uses product default, explicit override, or unique legacy registration (read-only)|PASS|PASS|一致|
|gateway reload deadline survives wall-clock offset -250ms|PASS|PASS|一致|
|gateway reload deadline survives wall-clock offset -30000ms|PASS|PASS|一致|
|gateway reload deadline survives wall-clock offset 0ms|PASS|PASS|一致|
|gatewayDirect has no production route profile|PASS|PASS|一致|
|gatewayDirect historical decode remains available|PASS|PASS|一致|
|general tabs are not authorisation pages; every flow protection is unchanged|PASS|PASS|一致|
|generic accounts and documentation/loopback addresses and example hosts pass|PASS|PASS|一致|
|git worktree is real, clean, isolated, and does not invoke checkout hooks|PASS|PASS|一致|
|git-supported unborn worktree remains usable without inventing a commit|PASS|PASS|一致|
|guard 1 functional: "*" in chatgpt/ is enough for normal git add; a nested repo lies; only --full-history sees a forced side-branch add|PASS|PASS|一致|
|guard 1: chatgpt/.gitignore keeps normal git add out; the entry git is asked from the entry (never from a nested repo); backups refuse chatgpt/ history|PASS|PASS|一致|
|guard 2: one shared policy (real path, any case, file identity) at the places that actually read, import, register or launch|PASS|PASS|一致|
|guard 3 functional: the probe script reports every leak kind without a sandbox and nothing but SELF_OK inside a deny profile|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|guard 3: the sandbox denies the whole entry except its own workspace folder, scratch and listed read-only paths; scratch itself cannot be swapped; no Data-volume alias|PASS|PASS|一致|
|hardlink scanner bounds variable dirents and retains fail-closed isolation|PASS|PASS|一致|
|headless acceptance covers fresh and actual legacy workspace, restart, filters, selection and persona|PASS|PASS|一致|
|headless checks exercise production refresh in temporary fixtures|PASS|PASS|一致|
|helper waits for exit, passes pinned version and prefetched path, and records success|PASS|PASS|一致|
|hidden and low-contrast label text is not reused as actionable labels|PASS|PASS|一致|
|hidden discussion rules ask first, forbid submission and contain all six headings|PASS|PASS|一致|
|hidden preamble and intervening-engine summary are in-memory only and bounded|PASS|PASS|一致|
|host shortcuts are claimed synchronously, menu actions do not depend on bindings|PASS|PASS|一致|
|host: one attempt at a time (same ID idempotent, other ID busy); window, transaction, scope, codes, grant bound to the attempt|PASS|PASS|一致|
|hotkey wiring: foreground+visible main window toggles the docked box, otherwise floats; second press closes|PASS|PASS|一致|
|hotkeys use Carbon RegisterEventHotKey (no accessibility permission), registered and removed in pairs|PASS|PASS|一致|
|human callbacks use visible native consent with coalesced allows and retryable denial|PASS|PASS|一致|
|human submit reuses coordinator review and submit with manual and stale-payload guards|PASS|PASS|一致|
|iPad MCP caller binding, image response and consent error propagation|PASS|PASS|一致|
|iPad USE stays reachable through Plugin > Pocket with the original consent thread|PASS|PASS|一致|
|iPad chat panel is presentation only, without discovery or authorization side effects|PASS|PASS|一致|
|icon and glass-chip buttons in 設定 › OS › 記憶, 開始使用 and the DM have accessibility names|PASS|PASS|一致|
|icon and store: third round icon Browser, target kept, send blocked while browsing|PASS|PASS|一致|
|icon buttons are one glass circle (in-box icons the size of the send button; top bar 44)|PASS|PASS|一致|
|identical source-name and repository-ID directories collapse deterministically|PASS|PASS|一致|
|identifiers stay: composer, chips, notices (with .action), plus the new ChatGPT line|PASS|PASS|一致|
|identifiers: every Browser and ［連線］ identifier from the inventory is kept; new pieces get new tatwo.dm.* ids|PASS|PASS|一致|
|identifiers: old ones kept on their successors, new ones named tatwo.dm.<name>|PASS|PASS|一致|
|identifiers: the sidebar, toolbar, search and what they open keep tatwo.dm.browser.* ids (and the Browser space components keep theirs)|PASS|PASS|一致|
|identity switches discard drafts but do not discard commands addressed to the new tab|PASS|PASS|一致|
|iframe activity preserves a committed document|PASS|PASS|一致|
|ignored file under a declared Package.swift input fails closed|PASS|PASS|一致|
|image is MCP image content, not clipped JSON/base64 persisted to ledger; external errors are codes only|PASS|PASS|一致|
|image preview presentation renders thumbnail, overlay and failure states without I/O wiring|PASS|PASS|一致|
|image-only uses a private file of native content blocks, never empty -p|PASS|PASS|一致|
|implicit default without mcp-config preserves normal bridges and denied host reply|PASS|PASS|一致|
|in-box key page: picker row, per-row key hints, capture pauses hotkeys, Esc leaves the page|PASS|PASS|一致|
|independent floating panel is non-activating, key-capable and on every Space and full-screen app|PASS|PASS|一致|
|index: main MEMORY.md within 200 lines / 25 KB, overflow to MEMORY-<source>.md; Codex summary 8 KB with marker|PASS|PASS|一致|
|inherited git overrides cannot redirect creation or exclusion into another repo|PASS|PASS|一致|
|initial navigation can still enter loading|PASS|PASS|一致|
|initial restoration reads registry selected tab and its URL|PASS|PASS|一致|
|injected media observer reports only kind + host, once per frame, via the existing callback|PASS|PASS|一致|
|injected mid-batch failure restores the complete before-state|PASS|PASS|一致|
|install receipt pointer selects one exact nonce-bound V3 receipt without second-granularity matching|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|install.sh and public/install.sh stay byte-identical|PASS|PASS|一致|
|installed namesake on another server stops creation even with an empty self-created list|PASS|PASS|一致|
|installer fails closed when source changes during the build phase|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|installer stages device files from its frozen source workspace, not the live checkout|PASS|PASS|一致|
|interface: HandsBuild.swift only adds (deviceID on projects, per-device login and unlock with defaults); the controller implements it|PASS|PASS|一致|
|interface: HandsConnectFlow keeps the R6a names and meanings (offer, cancel(reason:), phase, problem)|PASS|PASS|一致|
|interrupt RPC failure is visible and does not silently run queued work|PASS|PASS|一致|
|interrupt retains the prompt until the native child exits, then cleans it|PASS|PASS|一致|
|invalid concurrency fails closed before creating evidence or starting tests|PASS|PASS|一致|
|invalid room IDs cannot escape the managed room directory|PASS|PASS|一致|
|invalid symbols, languages and limits are rejected before any spawn|PASS|PASS|一致|
|inventory carries all three evidence columns and forbids deletion|PASS|PASS|一致|
|keyboard and overlay do not request permissions or use gamma tables|PASS|PASS|一致|
|keyboard in the tent: ⌘ shortcuts do not reach the main menu or the main window; Esc closes the box|PASS|PASS|一致|
|kinds: web = R5b sensitive CEF page; Pod = claim/release; Pod popup moved into the tab with its native window hidden|PASS|PASS|一致|
|label-for and wrapping labels describe fields without exporting their values|PASS|PASS|一致|
|language filtering, simple Swift/ObjC/JS definitions and no-match result|PASS|PASS|一致|
|last-moment text or button changes are rechecked rather than submitting a stale candidate|PASS|PASS|一致|
|late iframe does not invalidate a finished main document|PASS|PASS|一致|
|late steering acknowledgement is bound to the old turn, not its successor|PASS|PASS|一致|
|latest is only claimed after a successful comparison; errors remain visible even after later|PASS|PASS|一致|
|layering: main-window covers fold the docked panels; box sits above the composer|PASS|PASS|一致|
|lead: the R9 「新增 ▾」 Pod lease stays while the ChatGPT Dev page is on screen, including the inner-landscape right column|PASS|PASS|一致|
|legacy V3 import directory discovery is local, unambiguous and prefers the new default|PASS|PASS|一致|
|legacy email, token and key detection remains enforced|PASS|PASS|一致|
|legacy flow seams remain unchanged; executable Swift checks cover three reply cases|PASS|PASS|一致|
|legacy per-document overrides stay readable while constitution stays at entrance|PASS|PASS|一致|
|legacy signed plist preserves the vendor version through its exact wrapper-version pin|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|legacy unpersonalized temporary still adds history guard without guessing the native do-not-remember flag|PASS|PASS|一致|
|legacy v2.0.1 through v2.0.5 metadata exercises actual size/marker branches (not full install)|PASS|PASS|一致|
|lent tabs never sleep (sleep protection list), even under memory pressure|PASS|PASS|一致|
|linked-worktree exclusion stays idempotent under inherited git overrides|PASS|PASS|一致|
|linker-signed Mach-O and CMS use the same normalized unsigned content|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|links gain visible child labels without forwarding query strings or credentials|PASS|PASS|一致|
|live send dispatches prefixed TAP models before login gates or sidecar creation|PASS|PASS|一致|
|live startup selects GPT-6.1 Sol medium fast without changing fixture defaults|PASS|PASS|一致|
|live store refresh reaps every stale interrupted exchange|PASS|PASS|一致|
|load hysteresis waits for actual recovery|PASS|PASS|一致|
|loading recovery stops for idle, closed, blocked and stale browser lifecycles|PASS|PASS|一致|
|local and both remote fallbacks use assistant-free candidates, even for saved IDs|PASS|PASS|一致|
|local app installer builds, stages, ad-hoc signs, verifies, and atomically activates the canonical App|PASS|PASS|一致|
|local archives still pass through archive traversal/layout validation|PASS|PASS|一致|
|local cache rejects symlink directories, archives and preexisting temporary copies|PASS|PASS|一致|
|local confirmation action is not an RPC Boolean; revocation does not configure sshd|PASS|PASS|一致|
|local-only and forbidden entries cannot expose transfer paths|PASS|PASS|一致|
|location: <entry>/chatgpt/workspaces from the App entry resolver; App Support when isolated, missing, read-only, network or cloud|PASS|PASS|一致|
|logical entrance symlink saves into the target volume and commits its repo|PASS|PASS|一致|
|login and sleep block sends; stale catalog refreshes at send without waking a Pod|PASS|PASS|一致|
|macOS account paths and user/name fields reject non-generic names|PASS|PASS|一致|
|macOS names: case-only duplicates keep both versions; file/folder clashes stop the round|PASS|PASS|一致|
|main-frame loading stays loading until its own callback|PASS|PASS|一致|
|main.swift uses one portable top-level entrypoint instead of @main|PASS|PASS|一致|
|mainPane gates design, fails closed on forced selection and excludes composer|PASS|PASS|一致|
|malformed Goal mutation replies never acknowledge successful activation|PASS|PASS|一致|
|malformed device identity fails closed to secondary|PASS|PASS|一致|
|malformed or missing otool load-command output fails closed|PASS|PASS|一致|
|manual TOML drift is conflict and can never be reverse-adopted|PASS|PASS|一致|
|manual namesake card can point to the existing self-created entry without pressing it|PASS|PASS|一致|
|marker protects unmarked and edited content; writes are atomic|PASS|PASS|一致|
|memory card confirms inside the card with glass chips, never a system alert|PASS|PASS|一致|
|memory hysteresis prevents alternating pressure chatter|PASS|PASS|一致|
|memory/ git: Codex raw records local-only, secret-looking files held back|PASS|PASS|一致|
|menus stay between the header and the composer and scroll inside|PASS|PASS|一致|
|metadata is native, guarded by generation and identity; downloads retain W45 human store path|PASS|PASS|一致|
|minute-scale thinking reports progress instead of prematurely completing the turn|PASS|PASS|一致|
|missing cargo fails closed unless the explicit development skip is set|PASS|PASS|一致|
|missing document and missing/broken root reject saves without creating directories|PASS|PASS|一致|
|missing entrance, broken entrance/parent symlink, regular file and valid symlink differ|PASS|PASS|一致|
|missing fixture cannot silently disable full acceptance|PASS|PASS|一致|
|missing live store binding fails closed as incomplete/missing evidence|PASS|PASS|一致|
|missing or nil source appends standalone; absent artifact does not create a card|PASS|PASS|一致|
|missing paint-order evidence does not invent clickable controls|PASS|PASS|一致|
|missing project is not recreated as an empty successful room|PASS|PASS|一致|
|missing required input rejects before staging: TatwoIPadDevice.xcodeproj/project.pbxproj|PASS|PASS|一致|
|missing required input rejects before staging: TatwoIPadDevice.xcodeproj/project.xcworkspace/contents.xcworkspacedata|PASS|PASS|一致|
|missing required input rejects before staging: TatwoIPadDevice.xcodeproj/xcshareddata/xcschemes/TatwoIPadDevice.xcscheme|PASS|PASS|一致|
|missing required input rejects before staging: TatwoIPadDeviceTests/Info.plist|PASS|PASS|一致|
|missing required input rejects before staging: TatwoIPadDeviceTests/TatwoIPadDeviceTests.swift|PASS|PASS|一致|
|missing required input rejects before staging: project.yml|PASS|PASS|一致|
|missing resource bundle shows provider initials instead of terminating the app|PASS|PASS|一致|
|missing, malformed or mismatched local inputs retain official verification|PASS|PASS|一致|
|missing, paginated, or unreadable self-created section stays unknown even when installed is empty|PASS|PASS|一致|
|missing, unreadable, empty, unsupported and invalid attachments reject before spawning|PASS|PASS|一致|
|missing, zero, fractional and oversized backend IDs never become actionable node-index selectors|PASS|PASS|一致|
|mixed text, multiple images and quoted document references retain every attachment|PASS|PASS|一致|
|model chip is the Coder model chip (a Button, whole chip clickable) opening a native menu; primary name on its first line|PASS|PASS|一致|
|modifier detector has no AppKit dependency and triggers only at full release|PASS|PASS|一致|
|monitor is passive, local plus permission-gated global; permission can upgrade on activation|PASS|PASS|一致|
|moving the page: only the NSView moves; container.browserView is never cleared; the tab switcher is untouched|PASS|PASS|一致|
|multiple interrupted exchanges fail closed without choosing a history|PASS|PASS|一致|
|must-fix 1: per-device config with separate epochs; CAS on every change; one hostname per device; no single host claim or lease|PASS|PASS|一致|
|must-fix 2: background reconcile narrows, never retries; explicit disable revokes; polling never clears the safety lock|PASS|PASS|一致|
|must-fix 2: signed envelope with the existing device identity key; only the pinned primary key; rollback and same-revision-different-content refused|PASS|PASS|一致|
|must-fix 3: mailbox binds owner/target/operation/attempt/revision/epoch/expiry/payload hash; owner-only results; in memory only; B decides|PASS|PASS|一致|
|must-fix 3: the public status carries no login URL, confirm token or pairing code|PASS|PASS|一致|
|must-fix 4: login is only login (no auto domain, no adopt, no continue); apply builds URLs; resume and the assistant never create DNS|PASS|PASS|一致|
|must-fix 5: grants carry host, issuer/resource and revocation generation; exact resource on the App side; evidence v2 binds target/attempt/epoch|PASS|PASS|一致|
|must-fix 6: ownership kept on the primary; each device lists only tunnels it has evidence for; unknown ownership or DNS = list nothing|PASS|PASS|一致|
|must-fix 8: legacy single host migrates to "that one device selected" and never copies OAuth state|PASS|PASS|一致|
|mutating direct refresh requires an explicit shared-lock claim|PASS|PASS|一致|
|named personal domains and SSH aliases are rejected|PASS|PASS|一致|
|namesake on another URL is reported as a conflict and cannot be reconnected or deleted|PASS|PASS|一致|
|native Goal query is once per boot and cannot overwrite a newer notification|PASS|PASS|一致|
|native Island controller recovers missing exit and programmatic expansion|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|native Island hover exit collapses synchronously with no click or grace period|PASS|PASS|一致|
|native Quit confirms before synchronous CLI save/detach/finish, preserving bypass|PASS|PASS|一致|
|native address projection keeps draft and committed navigation distinct|SKIP|SKIP|一致|
|native conversation reuses OS components; only Dots presents its web page inside the Space|PASS|PASS|一致|
|native dispatch preserves frame token and human mount guards; Swift rechecks approval identity|PASS|PASS|一致|
|native display builder, preview projection and SwiftUI surface|PASS|FAIL|環境競用；序列重跑兩版 PASS|
|native feedback states and compact Chat/note presentation|PASS|PASS|一致|
|native fleet product and authorized command never depend on a script interpreter|PASS|PASS|一致|
|native gate: fixed socket, live policy, bounded frames, registration and startup under 0.2s|PASS|PASS|一致|
|native helper is Mach-O and links only macOS runtime libraries|PASS|PASS|一致|
|native iPad USE validation and consent checks|PASS|PASS|一致|
|native iPad chat presentation and thread-bound consent callbacks|PASS|PASS|一致|
|native mapping source: strict JSON false and website evidence, not queue acceptance; terminal cleanup|PASS|PASS|一致|
|native note store and panel preserve edits, selection and search|PASS|PASS|一致|
|native ownership ends at real close, not at view dealloc|PASS|PASS|一致|
|native packaging reports exact writer snapshot delta for upstream review|PASS|PASS|一致|
|native production readonly room decisions fail closed without construction or remote I/O|PASS|PASS|一致|
|native reservation cleanup preserves partial files, replacements and symlinks|PASS|PASS|一致|
|native shared hover opens without click, retains rows, closes on exit and cancels stale closes|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|native sidebar projection preserves hierarchy and routes local actions locally|PASS|PASS|一致|
|native steering waits for acknowledgement and does not start another turn|PASS|PASS|一致|
|native synthetic MCP card layout and all five liveness pills|PASS|PASS|一致|
|native window buttons remain visible with fresh-install unpinned sidebar and after navigation|PASS|PASS|一致|
|native-page continuation: authoritative ID survives read-error then poll completion without a route|PASS|PASS|一致|
|native-page continuation: completed proof stays at root; forced routing would destroy native state|PASS|PASS|一致|
|native-page continuation: missing proof or consent rejects send/edit/regenerate before navigation|PASS|PASS|一致|
|native-page continuation: navigation out/back including the matching ID route, or mode change, revokes proof|PASS|PASS|一致|
|native-page continuation: regenerate and edit retain the native page and exact request guards|PASS|PASS|一致|
|native-page continuation: send/edit/regenerate still require original flags and matching original body ID|PASS|PASS|一致|
|native-page regenerate: cancellation, navigation or mode reversal while opening retry menu cannot click Try again|PASS|PASS|一致|
|navigation failure is not cleared by resource activity|PASS|PASS|一致|
|navigation preserves focused drafts; committed URLs are persisted by the shared runtime|PASS|PASS|一致|
|nested .git directories are ignored consistently|PASS|PASS|一致|
|never destructive: no reset --hard, no clean, no deleting user files|PASS|PASS|一致|
|new Swift files exist (source list sanity)|PASS|PASS|一致|
|new active parent receives one alert and its own recovery|PASS|PASS|一致|
|new and restored blank tabs retain the original centered search page|PASS|PASS|一致|
|new build, install, queue and verification writers retain their reviewed paths and sync decisions|PASS|PASS|一致|
|new chat reset diagnostics: blocked/control-unconfirmed/unconfirmed exits expose booleans without changing refusal|PASS|PASS|一致|
|new chat reset diagnostics: cancellation/origin/latching during reset are observable, and the next reset clears stale flags|PASS|PASS|一致|
|new chat reset diagnostics: exact placeholder is distinguished from real or inconsistent whitespace|PASS|PASS|一致|
|new chat reset diagnostics: fixed booleans/enums for every combination, no unknown values|PASS|PASS|一致|
|new chat reset diagnostics: whitespace restored at selectComposer after a confirmed reset is still preserved|PASS|PASS|一致|
|new chat: Blob/Request decode cannot outlive cancel, navigation return or native mode reversal|PASS|PASS|一致|
|new chat: a draft restored after reset is preserved rather than replaced by the new send|PASS|PASS|一致|
|new chat: accepted first send may route before a later unrelated internal prepare|PASS|PASS|一致|
|new chat: even after confirmed reset original prepare/send must have no old CID or normal temporary flags|PASS|PASS|一致|
|new chat: missing/ambiguous/ineffective native reset, existing draft or Stop preserve page and refuse send|PASS|PASS|一致|
|new chat: native reset cancellation cannot insert or send after the native UI settles|PASS|PASS|一致|
|new chat: original prepare at insertion is guarded before pendingSend exists|PASS|PASS|一致|
|new chat: reset navigation away/back cannot become ready again, including after reset confirmation|PASS|PASS|一致|
|new chat: retained root temporary context cannot receive a normal new command|PASS|PASS|一致|
|new chat: root and routed prior proof require real native reset before normal or personalized new|PASS|PASS|一致|
|new chat: root normal after normal with DOM gone still rejects original old ID, without claiming reset|PASS|PASS|一致|
|new chat: valid one-shot stream bodies are inspected once and remain dispatchable|PASS|PASS|一致|
|newest local readback wins so an older green cannot shadow a newer red|PASS|PASS|一致|
|next and loopStatus stateless fallbacks are pure projectContract projections|PASS|PASS|一致|
|next locked refresh reaps stale staging before creating a new stage|PASS|PASS|一致|
|next refresh restores a single interrupted compensating exchange|PASS|PASS|一致|
|no ChatPageModel.send / func send / botDispatcher / gateway.dispatch in BotPage*|PASS|PASS|一致|
|no Line / Discord / Telegram SDK import in BotPage files|PASS|PASS|一致|
|no UserDefaults / FileManager writes in BotPage files|PASS|PASS|一致|
|no WKWebView in BotPage files or ChatPage|PASS|PASS|一致|
|no capture shield in the tent; the main window keeps a placeholder with 拿回來 that the CEF container yields to|PASS|PASS|一致|
|no general-chat fallback, and old project conversation cannot be used in inbox|PASS|PASS|一致|
|no hard-coded domains or host names in the new files|PASS|PASS|一致|
|no local options preserves official source, SHA, cache and index receipt|PASS|PASS|一致|
|no offline-cache file I/O on the main thread: one serial queue, the mirror only goes through cache.run|PASS|PASS|一致|
|no runner / gateway / MCP / sandbox service import in BotPage files|PASS|PASS|一致|
|no second authorization issuer entrypoint exists|PASS|PASS|一致|
|no unsolicited pressure messages in selected idle chat|PASS|PASS|一致|
|no-tab search (W184 G2d): the main window's centered search box (BrowserStartSearch) — no tabs or a blank tab; typing opens a general tab|PASS|PASS|一致|
|non-fleet legacy ACK retains signed authentication, handoff ledger and all refusal guards|PASS|PASS|一致|
|non-fleet legacy ACK retains signed authentication, handoff ledger and all refusal guards › W221d claimed phase differing from the verified decoded receipt is refused in both directions|PASS|PASS|一致|
|non-fleet legacy ACK retains signed authentication, handoff ledger and all refusal guards › W221d non-fleet legacy ACK preserves old unsplit pin and handoff guards|PASS|PASS|一致|
|non-owner payload is refused and same-hash apply does not rewrite server|PASS|PASS|一致|
|nonempty feedback uses the canvas and ordinary send; bare feedback keeps the old panel|PASS|PASS|一致|
|normal CEF tab initialization reuses a secured context without popup flags or policy bypass|PASS|PASS|一致|
|normal launch starts the shared display service after the early selftest hook|PASS|PASS|一致|
|npm hidden lockfile drift adopts baseline bytes only when the node_modules tree is otherwise identical|PASS|PASS|一致|
|occluded controls are not offered as click targets|PASS|PASS|一致|
|official CLI and MCP begin routes are typed, same-root, and bootstrap-free|PASS|PASS|一致|
|offline copy lives in live/remote-cache/<device id>/: document.json + last 200 messages of read threads, capped, atomic|PASS|PASS|一致|
|offline handoff: the local assistant runs here and its first turn carries the primary context once|PASS|PASS|一致|
|offline stretch merges back into the primary thread: text and time only, marked, deduped, no engine|PASS|PASS|一致|
|old disabled/hidden/aria-disabled candidates never mask the valid current send button|PASS|PASS|一致|
|omnibox waits for a live holder to release without taking its lock (no compiler)|PASS|PASS|一致|
|onChange of model.mode only starts terminal on .cli|PASS|PASS|一致|
|one complete shared chrome/shortcut owner; explicit AnyView breaks the recursive Body type|PASS|PASS|一致|
|one definition, exactly three references, grouped counts and word boundaries|PASS|PASS|一致|
|one failed source among valid sources remains explicit and never activates a partial store|PASS|PASS|一致|
|one lock for commit / merge / write; watcher reads under it|PASS|PASS|一致|
|one owner registry, no stored facade dictionary or workspace demo folders|PASS|PASS|一致|
|one sidebar control lives before navigation; the space title has no second control|PASS|PASS|一致|
|one-confirmation authorization binds the consent thread|PASS|PASS|一致|
|only confirmation starts implementation with editable plan; completion cannot submit|PASS|PASS|一致|
|only running children notify their existing parent|PASS|PASS|一致|
|only successful terminal reply updates its owning plan, keeping transcript fence|PASS|PASS|一致|
|only the two approved fixture-local Toggle bindings are permitted|PASS|PASS|一致|
|opening: the DM box opens by itself, switches to Browser, the tab is in front; all tabs gone → the box goes back as it was|PASS|PASS|一致|
|optional artifact kind decodes old JSON and shares the labelled fence parser|PASS|PASS|一致|
|ordinary files stay explicit file references rather than fake image blocks|PASS|PASS|一致|
|ordinary folders retain supported room creation but cannot reuse a room|PASS|PASS|一致|
|os-image compare treats same hashes as aligned and app drift as diverged|PASS|PASS|一致|
|os-image default OS skill slot is skillet not tatwo-ultrawork|PASS|PASS|一致|
|os-image fixture isolates the busy gate and still defers before an idle apply|PASS|PASS|一致|
|os-image publish is content-addressed and apply restores runtime files|PASS|PASS|一致|
|os-image refuses to publish a torn live tree|PASS|PASS|一致|
|os-mcp transport: computer_observe windowID reaches the App as given, malformed ones never do|PASS|PASS|一致|
|other forms are never clicked, including a global dedicated ID before the current form|PASS|PASS|一致|
|overview_snapshot wire is an explicit allowlist and the bridge serves it to paired devices only|PASS|PASS|一致|
|owned synthetic model runtime only answers --version and traps actual execution|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|owner-initiated cycle publishes roster and applies without touching credentials or identity overlay|PASS|PASS|一致|
|page: glass chip at the top, proposals and recent moves, in-card confirm row, no system dialogs|PASS|PASS|一致|
|pairing code: only to the owner, only after the Pod-observed authorize params match the transaction; mismatch terminates|PASS|PASS|一致|
|pairing copy is a user button, shown only with visible, unexpired code|PASS|PASS|一致|
|parallel discovery has one five-second device budget, bounded transfers and fixture gate before Process|PASS|PASS|一致|
|path-like CLI must be executable|PASS|PASS|一致|
|paths come from parameters or the environment; no real HOME in the self-test; no secrets logged|PASS|PASS|一致|
|pending stop also works when the ID arrives only in the RPC reply|PASS|PASS|一致|
|per-file collapsed diff shows counts and caps only preview at 400 lines; GitHub login is in canvas|PASS|PASS|一致|
|per-turn rule uses existing outgoing vs displayed text split, not session prompt|PASS|PASS|一致|
|perf script syntax and honest D-B6 measurement surfaces|PASS|PASS|一致|
|permanently disabled send times out without overriding page limits or attempting replay|PASS|PASS|一致|
|permissions describe actual scopes instead of claiming ungranted access|PASS|PASS|一致|
|persistent surface without policy fails closed|PASS|PASS|一致|
|persistent toolbar follows the workspace theme instead of the native white control fill|PASS|PASS|一致|
|personal identifiers come only from the private list, also when split into fragments; the list never ships|PASS|PASS|一致|
|personalization is an explicit per-chat opt-in in both clients, not a global default or tool inference|PASS|PASS|一致|
|personalized temporary: asynchronous body decoding cannot bypass the last native mode recheck|PASS|PASS|一致|
|personalized temporary: cancellation during native mode wait never inserts or submits later|PASS|PASS|一致|
|personalized temporary: deliberate native menu choice is read back, not inferred from a click|PASS|PASS|一致|
|personalized temporary: empty new page and visible native mode allow one bounded send|PASS|PASS|一致|
|personalized temporary: explicit consent without temporary flag still blocks|PASS|PASS|一致|
|personalized temporary: message content, forms, hidden controls and ambiguous buttons are not mode evidence|PASS|PASS|一致|
|personalized temporary: missing native evidence or URL-only evidence blocks before insertion|PASS|PASS|一致|
|personalized temporary: mode changing after insertion is checked again before submit|PASS|PASS|一致|
|personalized temporary: native draft or existing message is preserved rather than switching its mode|PASS|PASS|一致|
|personalized temporary: native mode cannot replace the original body privacy guard|PASS|PASS|一致|
|personalized temporary: native toggle must settle before any insertion or submit|PASS|PASS|一致|
|personalized temporary: prior native personalization never implies this conversation consent|PASS|PASS|一致|
|personalized temporary: queued toggle-on mutation predating proof cannot revoke the first turn|PASS|PASS|一致|
|pinned git environment shared with clonePrimaryMemory (behaviour unchanged)|PASS|PASS|一致|
|pinned memory git accepts a paired record without a role field (legacy pairing), rejects an explicit non-primary role|PASS|PASS|一致|
|plan emits exact full-file unified diff and detects managed update|PASS|PASS|一致|
|plan is real state, with exact slash token and reopen request|PASS|PASS|一致|
|plan production parser handles complete/incomplete/multiple and nested fences|PASS|PASS|一致|
|plan remains discussion-only; execution no longer mandates a dispatch room|PASS|PASS|一致|
|pod account identity: login id, workspace and email only (for comparison); commands never run off chatgpt.com|PASS|PASS|一致|
|pod connector: OAuth from a listbox combobox (options rendered outside the dialog)|PASS|PASS|一致|
|pod connector: URL rewritten by the page → refused, Create not pressed|PASS|PASS|一致|
|pod connector: a newer command or connectorAbort stops an older one before its next action (no late press)|PASS|PASS|一致|
|pod connector: an unchecked trust box or a warning goes to the user (never ticked, never pressed); resume with the seen form + warning presses once|PASS|PASS|一致|
|pod connector: create fills name, exact URL and OAuth, reads back, then presses Create once|PASS|PASS|一致|
|pod connector: guided mode only highlights (no clicks), home clears the highlight|PASS|PASS|一致|
|pod connector: more than one "+" or more than one form or no form → stop, never guess|PASS|PASS|一致|
|pod connector: only well-formed https MCP URLs, never chatgpt.com/openai.com; commands do nothing outside chatgpt.com|PASS|PASS|一致|
|pod connector: resume without the seen form (e.g. developer mode auto-resume) never treats a new form's warning as read|PASS|PASS|一致|
|pod connector: scan identifies an existing connector by exact MCP URL + OAuth (not by name) and reads developer mode|PASS|PASS|一致|
|pod connector: unreadable list is reported as unknown (App will not press create); dev mode off is visible|PASS|PASS|一致|
|pod privacy: backend-api reads are no-store, and the Pod HTTP cache is purged before the first start each launch|PASS|PASS|一致|
|pod reconnect: a longer URL that merely starts with ours (…/mcp/extra) is not our connector|PASS|PASS|一致|
|pod reconnect: no id link on the page → not_found, even when the page text shows the full URL and another app has a unique Connect|PASS|PASS|一致|
|pod reconnect: opens only the connector the list identified (id link), reads back URL/auth inside its detail box, presses its one Connect|PASS|PASS|一致|
|pod reconnect: two Connect buttons in the detail box → ambiguous; a detail box saying No Auth → refused|PASS|PASS|一致|
|pod scan: only a complete, recognised list counts as known (paged or unknown shapes stay unknown → the App never presses Create)|PASS|PASS|一致|
|pod script W184 G3c: a temporary send with a JSON array (the flag cannot stick) is blocked — never sent, reported as a failure, no conversation|PASS|PASS|一致|
|pod script W184 G3c: a temporary send with a body it cannot read (a plain object) is blocked — never sent, reported as a failure, no conversation|PASS|PASS|一致|
|pod script W184 G3c: a temporary send with a body that is not JSON (the rewrite throws) is blocked — never sent, reported as a failure, no conversation|PASS|PASS|一致|
|pod script W184 G3c: a temporary send with a non-string body is read as text, flagged, confirmed, and only then sent|PASS|PASS|一致|
|pod script W184 G3c: a temporary turn the page completes without our send path is a failure, never a conversation|PASS|PASS|一致|
|pod script: + menu ranks Deep research third like the web and keeps OpenAI's own apps off the first level|PASS|PASS|一致|
|pod script: + menu ranks tools like the web and marks connected apps|PASS|PASS|一致|
|pod script: a handed-off answer is polled from the conversation until it finishes|PASS|PASS|一致|
|pod script: a new chat in a project is sent from the project page|PASS|PASS|一致|
|pod script: a new chat switches the page to Chat (not Work) and the chosen effort is applied|PASS|PASS|一致|
|pod script: a placeholder on the page ("Pro thinking") does not end an empty-stream turn; the server answer does|PASS|PASS|一致|
|pod script: a sources footnote whose matched text is a space does not delete every space in the answer|PASS|PASS|一致|
|pod script: account falls back to the sign-in name when the ChatGPT profile is unavailable|PASS|PASS|一致|
|pod script: after a stream_handoff, a follow-up event stream from the page is parsed for the same turn|PASS|PASS|一致|
|pod script: an empty send stream with a known conversation falls back to polling the conversation|PASS|PASS|一致|
|pod script: answers carry their web sources; image refs and non-http links are left out|PASS|PASS|一致|
|pod script: attachments are handed to the page's own file input before sending|PASS|PASS|一致|
|pod script: citation markers become the markdown links ChatGPT provides; widget markers are dropped|PASS|PASS|一致|
|pod script: every message of a temporary chat carries history_and_training_disabled; normal chats do not|PASS|PASS|一致|
|pod script: feedback posts thumbs up/down for a message|PASS|PASS|一致|
|pod script: image replies come back as images (pointer + size) on the answer, tool text stays out|PASS|PASS|一致|
|pod script: images load by file id from any pointer form, with or without a conversation|PASS|PASS|一致|
|pod script: legacy full-message stream still shows the growing answer|PASS|PASS|一致|
|pod script: library lists files like the web (suggested / images / all) and fetches thumbnails|PASS|PASS|一致|
|pod script: list, get and models go through the page's own headers and return only what the App needs|PASS|PASS|一致|
|pod script: model variants merge into one effort slider, Work-only models are hidden, and the page choice is reported|PASS|PASS|一致|
|pod script: new-chat headline comes from the page when ChatGPT has no greeting|PASS|PASS|一致|
|pod script: only on chatgpt.com, captures auth once, hello says logged in, never reports tokens|PASS|PASS|一致|
|pod script: picker v2 turns versions × intelligence presets into the web's menu and maps the page choice back|PASS|PASS|一致|
|pod script: pins and projects come back as folders; project conversations are listed|PASS|PASS|一致|
|pod script: plugin detail maps the web's plugin page and splits connector tools into read and write like the web|PASS|PASS|一致|
|pod script: probe never presses Pin/Delete; pin toggles press the page's own Pin/Unpin button|PASS|PASS|一致|
|pod script: regenerate goes through "Switch model" and presses "Try again" in its menu|PASS|PASS|一致|
|pod script: regenerating with another preset swaps the model on the page's own request|PASS|PASS|一致|
|pod script: rename, archive and delete PATCH the conversation; search uses the server search|PASS|PASS|一致|
|pod script: retrying with a model that has no reasoning effort drops the page's effort|PASS|PASS|一致|
|pod script: scheduled tasks, plugins, sites, memories, instructions and account map only what the App shows|PASS|PASS|一致|
|pod script: send types into the page, swaps the model and streams v1 deltas|PASS|PASS|一致|
|pod script: sending after switching versions (or editing) continues from the chosen node|PASS|PASS|一致|
|pod script: share presses the page's own Share chat and captures the link without touching the clipboard|PASS|PASS|一致|
|pod script: stop sharing deletes a conversation share like the web's Shared links trash and checks the public page|PASS|PASS|一致|
|pod script: the current preset comes from the server's last-used model config, the way the web reads it|PASS|PASS|一致|
|pod script: the old /backend-api/conversation send path is intercepted too, and project sends carry conversation_mode|PASS|PASS|一致|
|pod script: the stop button vanishing while the send stream is still open and silent does not end the turn|PASS|PASS|一致|
|pod script: the web sheet can open settings and ChatGPT pages|PASS|PASS|一致|
|pod script: tools, home suggestions and GPTs are read; a tool rides along as system_hints; a GPT chat opens /g/<id> first|PASS|PASS|一致|
|pod script: versions (‹ 1/2 ›) come with each turn; a branch shows that version down to its newest reply|PASS|PASS|一致|
|pod script: voice clears leftover text in the page composer before looking for the speech button|PASS|PASS|一致|
|pod script: voice mode presses the page's Start Voice and ends with End voice mode|PASS|PASS|一致|
|pod script: when the stream cannot be parsed, the answer comes from the page and the id from the URL|PASS|PASS|一致|
|pod script: while the page already shows this turn's answer bubble, polling does not give up after two minutes|PASS|PASS|一致|
|pod tools: a subsequent fetch sees newly connected apps without reloading the Pod|PASS|PASS|一致|
|pod tools: malformed or unavailable catalogs fail instead of replacing the last list with empty|PASS|PASS|一致|
|portable manifest contract does not serialize target-local path fields|PASS|PASS|一致|
|preboot stop cancels old activation without RPC before init and preserves explicit later Goal|PASS|PASS|一致|
|prefetch skips only ZIP; remote checksum and SHA comparison remain mandatory|PASS|PASS|一致|
|prepare diagnostics: current safe snapshot does not erase block, later successful prepare clears it|PASS|PASS|一致|
|prepare diagnostics: renderer only emits allowlisted enums and strict booleans|PASS|PASS|一致|
|prepare executes locked cargo with the selected Rust home and copies helper/license/manifest|PASS|PASS|一致|
|prepare rerender: hidden role-dialog skeleton is allowed; detached old box is never cleared|PASS|PASS|一致|
|prepare rerender: picker accepts exact empty empty without touching detached box|PASS|PASS|一致|
|prepare rerender: picker accepts exact empty p_br without touching detached box|PASS|PASS|一致|
|prepare rerender: picker accepts exact empty textarea without touching detached box|PASS|PASS|一致|
|prepare rerender: picker rejects unsafe replacement without altering either box|PASS|PASS|一致|
|prepare rerender: selection accepts exact empty empty without touching detached box|PASS|PASS|一致|
|prepare rerender: selection accepts exact empty p_br without touching detached box|PASS|PASS|一致|
|prepare rerender: selection accepts exact empty textarea without touching detached box|PASS|PASS|一致|
|prepare rerender: selection rejects unsafe replacement without altering either box|PASS|PASS|一致|
|prepare rerender: toggle accepts exact empty empty without touching detached box|PASS|PASS|一致|
|prepare rerender: toggle accepts exact empty p_br without touching detached box|PASS|PASS|一致|
|prepare rerender: toggle accepts exact empty textarea without touching detached box|PASS|PASS|一致|
|prepare rerender: toggle rejects unsafe replacement without altering either box|PASS|PASS|一致|
|pressure capability does not advertise touch synthesis as Pencil support|PASS|PASS|一致|
|previous evidence is preserved and no build runs|PASS|PASS|一致|
|primary never commits a legacy docs override outside entrance repo|PASS|PASS|一致|
|primary outbox: three actions only, atomic file, in-order flush through the original methods|PASS|PASS|一致|
|primary receive: commit local first, exact inbox ref, only regular files, same merge rule, inbox cleared|PASS|PASS|一致|
|primary saves issue and commits only that file, preserving other staged/unstaged work|PASS|PASS|一致|
|primary saves todo and commits only that file, preserving other staged/unstaged work|PASS|PASS|一致|
|privacy diagnostics: only allowlisted booleans/types, never prompt, body, tokens or unknown values|PASS|PASS|一致|
|privacy: no private terms (docs/private-privacy-terms.txt) and no hardcoded device names in the new sources|PASS|PASS|一致|
|private IPv4 ranges include boundaries and mapped IPv6, but not adjacent public ranges|PASS|PASS|一致|
|private downloads use asset IDs; credentials stay out of resume files/helper and cross-host redirects|PASS|PASS|一致|
|private installer executes authenticated adapter with tag-pinned shared guards and no public network|PASS|PASS|一致|
|private symbols have runtime availability checks and no direct binding calls|PASS|PASS|一致|
|probe opens a read-only discovery session and does not call setters|PASS|PASS|一致|
|probe returns only a boolean, without reading content or media URLs|PASS|PASS|一致|
|production PR lifecycle, persistence, fork discovery and retry boundaries|PASS|PASS|一致|
|production RPC authorization accepts CRLF without treating Unicode separators as SSH lines|PASS|PASS|一致|
|production Swift catalog lifecycle: coalesce|PASS|PASS|一致|
|production Swift catalog lifecycle: disconnect-drops-pending|PASS|PASS|一致|
|production Swift catalog lifecycle: dm-default-isolated|PASS|PASS|一致|
|production Swift catalog lifecycle: dm-plus-edges|PASS|PASS|一致|
|production Swift catalog lifecycle: dm-shared-injection|PASS|PASS|一致|
|production Swift catalog lifecycle: dm-slash-shared-coalescing|PASS|PASS|一致|
|production Swift catalog lifecycle: duo-default-isolated|PASS|PASS|一致|
|production Swift catalog lifecycle: duo-injected-callback|PASS|PASS|一致|
|production Swift catalog lifecycle: duo-shared-injection|PASS|PASS|一致|
|production Swift catalog lifecycle: empty-success|PASS|PASS|一致|
|production Swift catalog lifecycle: failure-retains-and-retries|PASS|PASS|一致|
|production Swift catalog lifecycle: failure-with-pending-invalidation|PASS|PASS|一致|
|production Swift catalog lifecycle: invalidate-during-request|PASS|PASS|一致|
|production Swift catalog lifecycle: late-disconnected-response|PASS|PASS|一致|
|production Swift catalog lifecycle: pairing-bootstrap-deferred|PASS|PASS|一致|
|production Swift catalog lifecycle: pairing-connected-refresh|PASS|PASS|一致|
|production Swift catalog lifecycle: pairing-invalidates-inflight|PASS|PASS|一致|
|production Swift catalog lifecycle: pairing-offline-then-ready|PASS|PASS|一致|
|production Swift catalog lifecycle: pod-ready-again|PASS|PASS|一致|
|production Swift catalog lifecycle: pod-ready-during-request|PASS|PASS|一致|
|production Swift catalog lifecycle: ready-and-reopen|PASS|PASS|一致|
|production Swift catalog lifecycle: reconnect-during-request|PASS|PASS|一致|
|production Swift catalog lifecycle: shared-publisher-preserves-composer|PASS|PASS|一致|
|production Swift catalog lifecycle: space-slash-missing-match|PASS|PASS|一致|
|production Swift fixture migrates legacy three tabs and verifies custom lifecycle with Browser off/on|PASS|PASS|一致|
|production Swift fixture: cold/warm/reentrant queue, owner routing, selection restore and last-close round-trip|PASS|PASS|一致|
|production Swift omnibox, settings persistence and adaptive sleep boundary|PASS|PASS|一致|
|production Swift start predicate and planContext enforce two-stage and PR isolation|PASS|PASS|一致|
|production Swift transfer and engine content-cache synthetic fixtures|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|production Swift versions and retired private channel reject every marker/token combination|PASS|PASS|一致|
|production Swift: registry/available round-trip, LAN order, argv, capture-only, timeout and cancellation|PASS|PASS|一致|
|production activity reducer rejects stale frame contexts and keeps edit state sticky|PASS|PASS|一致|
|production attachment tiles render previews without overflowing adjacent files|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|production authorized reader retains BOM, CRLF, blank rows and missing final newline byte for byte|PASS|PASS|一致|
|production browser script completes 200 turns in one conversation and releases each round|PASS|PASS|一致|
|production builder emits only production-intent markers before promotion|PASS|PASS|一致|
|production bundle explicitly launches App MCP on a validated portable port|PASS|PASS|一致|
|production bundle fails closed on missing resources and writes an evidence receipt|PASS|PASS|一致|
|production cancellation freezes its group before kill; TERM control can still execute a shell trap|PASS|PASS|一致|
|production checker ignores legacy repository preference and sends no credentials|PASS|PASS|一致|
|production continuation processes work after load and in modal modes, then stops|PASS|PASS|一致|
|production durable writer discovery matches the reviewed source snapshot|PASS|PASS|一致|
|production feedback actions wait for a second click and re-review changed payloads|PASS|PASS|一致|
|production installer keeps its production gate and exposes a separate local-App mode|PASS|PASS|一致|
|production lifetime token closes abandoned owners and aggregates real completion|PASS|PASS|一致|
|production loading callback releases a retained human document after attachment navigation without reviving old grants|PASS|PASS|一致|
|production native keyboard/menu branches consume only handled human input and dispatch every PDF action|PASS|PASS|一致|
|production permission callback asks for multiple downloads, dismisses unsupported/stale requests, and denies agents|PASS|PASS|一致|
|production prefetch decision executes SHA gates and per-archive fallback with isolated I/O doubles|PASS|PASS|一致|
|production refresh waits for the shared writer lock and preserves the writer|PASS|PASS|一致|
|production resource callbacks isolate subresources and stale DNS errors|SKIP|SKIP|一致|
|production runtime fixture: lazy mount, switch retention, background callbacks, sleep/wake and popup owner|PASS|PASS|一致|
|production scroll-follow state preserves reading intent through lazy layout|PASS|PASS|一致|
|production tatwo-loop dispatch binds manifest, session, grant, and exact route|PASS|PASS|一致|
|production typing refuses a mismatched observed URL and an embedded frame|PASS|PASS|一致|
|production uses node-bound data arguments and no global event injection|PASS|PASS|一致|
|production window realigns native lights after AppKit ordering, content changes and resize|PASS|PASS|一致|
|profile-owner completion waits for all real and accepted-pending popup descendants|PASS|PASS|一致|
|prohibited Skill content remains a per-source failed local attempt without activation|PASS|PASS|一致|
|project collision resolution has one owner shared by the returned name and default folder|PASS|PASS|一致|
|project map has only metadata, atomic private writes and symlink refusal|PASS|PASS|一致|
|project map page: grouped by device, offline groups disabled, rooms under parents, open in Coder|PASS|PASS|一致|
|project send: when the page stays on the project page, the new conversation is found in the project list and polled|PASS|PASS|一致|
|projection and canonical mutation are different typed APIs|PASS|PASS|一致|
|promote archive validation rejects macOS case/Unicode collisions before extraction|PASS|PASS|一致|
|promote rejects absent authorization and non-TTY before side effects; public package denied|PASS|PASS|一致|
|promote revalidates before staging/publication; withdraw preserves recovery material|PASS|PASS|一致|
|promote verifier executes offline layer assembly and exact DR gate on disposable sealed fixtures|PASS|PASS|一致|
|promoted primary discovers aliased skills by repository ID with stable identity|PASS|PASS|一致|
|proof diagnostics: before-continuation snapshot and revocation reasons contain only fixed states/booleans|PASS|PASS|一致|
|protections kept: Computer Use gate while any sensitive tab exists; no screen capture while an unfinished one is on screen; DM switch off closes all|PASS|PASS|一致|
|public blocklist serialization preserves the original non-personal ad domain|PASS|PASS|一致|
|public endpoint is fixed and onboarding cannot select or persist a private channel|PASS|PASS|一致|
|publish refuses credential-looking roster keys|PASS|PASS|一致|
|pure classifier: native BUTTON and role-only are distinct, neither invents a legacy candidate|PASS|PASS|一致|
|pure classifier: retains known testid and exact same-origin root-anchor semantics|PASS|PASS|一致|
|pure classifier: unrelated labels and non-root/foreign/query/hash anchors are rejected|PASS|PASS|一致|
|pure projection: no writes, files, network or message content; Island classification, not re-derived|PASS|PASS|一致|
|push_thread uses per-thread provenance and actual peer baseline preflight|PASS|PASS|一致|
|quarantine and both submission scanners use bounded names, never copy a dirent tuple|PASS|PASS|一致|
|read started during a Goal mutation cannot suppress the successful mutation snapshot|PASS|PASS|一致|
|read-only screenshot timeout preserves consent without a fixed authorization timeout|PASS|PASS|一致|
|readOnly mounts only native read tools despite supplied writable MCP and bridge endpoints|PASS|PASS|一致|
|readOnly resume keeps the same closed tool/settings surface|PASS|PASS|一致|
|readOnly without mcp-config remains strict and bridge-free|PASS|PASS|一致|
|read_session exposed with schema and dispatch|PASS|PASS|一致|
|reader: goal files and SSH only off the main thread, 15 s remote, stops on disappear, no new get_document|PASS|PASS|一致|
|readiness digest uses receipt-backed target heads and matches Swift tuple serialization|PASS|PASS|一致|
|real AppKit composer does not publish stale or unlaid-out heights|PASS|PASS|一致|
|real MCP stdio forwards read selectors and explicit submit without leaking extra snapshot fields|PASS|PASS|一致|
|real Mach-O: executable and loader LC_RPATH, inherited runpaths, dylib ID and symlink resolve to exact files|PASS|PASS|一致|
|real Swift download lifecycle, origin-only history and retryable native consent|PASS|PASS|一致|
|real certificate cannot be reused under a requested ad-hoc identity|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|real codesign: reuse, deterministic zip despite mtimes, sealed zero-difference reassembly|PASS|PASS|一致|
|real five-helper CEF bundles pass production verification while direct otool reproduces the parenthesized executable truncation|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|real installer download/checksum block accepts cache, rejects tampering and preserves terminal download|PASS|PASS|一致|
|real or symlinked ~/.codex roots are rejected without explicit acknowledgement|PASS|PASS|一致|
|real quarantine scan survives large directory buffers and preserves isolation decisions|PASS|PASS|一致|
|real repo CLI smoke: node scripts/impact.mjs BrowserActor exits zero with a hit|PASS|PASS|一致|
|real same-slot swap commits, verifies signing, then injected post-receipt failure rolls back bytes and Contents|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|real shortcut model migrates legacy defaults, preserves custom maps and routes standard keys|PASS|PASS|一致|
|real stdio catalog + UNIX socket forwards exact WebMCP methods and rejects authority overrides|PASS|PASS|一致|
|real suffix-free mktemp succeeds twice in the same TMPDIR|PASS|PASS|一致|
|real thrice runner defaults to 2 and records explicit concurrency 1 or 2 without filtering or retries|PASS|PASS|一致|
|real thrice runner distinguishes stable clean from an empty intersection with intermittent failures|PASS|PASS|一致|
|real thrice runner executes every file three times even after failures and separates identical titles|PASS|PASS|一致|
|real thrice runner rejects source drift and never overwrites an existing evidence directory|PASS|PASS|一致|
|rebuilding the same staging runtime preserves its PLG anchor identity|PASS|PASS|一致|
|receipt-backed active head that differs from canonical is excluded like Swift matchingDeviceReceipt|PASS|PASS|一致|
|reconnect backoff is capped at one minute so a returning primary syncs quickly|PASS|PASS|一致|
|reconnect recovery: a missing name or off-origin namesake never presses anything|PASS|PASS|一致|
|reconnect recovery: an already-open ID detail works only when the current route identifies that ID|PASS|PASS|一致|
|reconnect recovery: an already-open named detail works without a list link; URL and OAuth are still checked|PASS|PASS|一致|
|reconnect recovery: delayed ID links are awaited instead of treating URL navigation as a loaded list|PASS|PASS|一致|
|reconnect recovery: duplicate named links are ambiguous and never pressed|PASS|PASS|一致|
|reconnect recovery: missing OAuth evidence is refused, including a change after arming|PASS|PASS|一致|
|reconnect recovery: same-origin absolute name links work and unrelated detail routes return to the list|PASS|PASS|一致|
|records remember where each workspace lives; a workspace is created only in the location that was just verified (review: stale location)|PASS|PASS|一致|
|recovery is projection-only and fixture writers are isolated from production|PASS|PASS|一致|
|recursive current-session path aliases and mutation sinks are closed-world inventoried|PASS|PASS|一致|
|redaction prevents secret/token leakage in receipt output|PASS|PASS|一致|
|refresh API uses runtime override, bundle resource, injectable time and CryptoKit|PASS|PASS|一致|
|refresh fails closed when a Unicode skill lacks an ASCII alias|PASS|PASS|一致|
|refresh maps Unicode display aliases to portable repository IDs|PASS|PASS|一致|
|refresh rejects a CLI claim whose immutable object does not verify|PASS|PASS|一致|
|refresh rejects a self-consistent snapshot of the wrong source content|PASS|PASS|一致|
|refresh remains compatible with direct legacy snapshot JSON|PASS|PASS|一致|
|refresh removes the staged store mutation lock created by the real CLI|PASS|PASS|一致|
|refresh reports stale repositories instead of silently syncing them|PASS|PASS|一致|
|refresh unwraps the governed CLI JSON envelope|PASS|PASS|一致|
|refuses checkbox controls|PASS|PASS|一致|
|refuses file controls|PASS|PASS|一致|
|refuses hidden controls|PASS|PASS|一致|
|refuses password controls|PASS|PASS|一致|
|refuses radio controls|PASS|PASS|一致|
|refuses unsafe or unavailable field {"attributes":{"aria-label":"Credit card number"}}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"autocomplete":"one-time-code"}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"disabled":true}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"isConnected":false}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"name":"[fixture field name redacted]"}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"ownerDocument":{}}|PASS|PASS|一致|
|refuses unsafe or unavailable field {"readOnly":true}|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › builder host escalation|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › duplicate id|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › gpt-5.4|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › gpt-5.4-mini|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › luna|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › path traversal|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › protected flag|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › reviewer supervisor escalation|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › unknown effort|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › unknown preset key|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › unknown registry key|PASS|PASS|一致|
|registry validation fails closed for forbidden models and identity pollution › unwhitelisted native extra|PASS|PASS|一致|
|rejected native settings cannot activate a Goal using silent defaults|PASS|PASS|一致|
|rejected projection is visible by device name with an update hint|PASS|PASS|一致|
|rejected steering preserves the active native turn and permits explicit retry|PASS|PASS|一致|
|rejected stopped start releases only its turn; explicit new work survives|PASS|PASS|一致|
|relative or recursively-tokenized LC_RPATH is rejected, never searched from cwd|PASS|PASS|一致|
|relaunch at pgrep check 1 prevents install and open|PASS|PASS|一致|
|relaunch at pgrep check 2 prevents install and open|PASS|PASS|一致|
|relaunch checks use the packaged executable name, not the SwiftPM product name|PASS|PASS|一致|
|release-train checksum verifier executes and rejects corrupt artifacts|PASS|PASS|一致|
|relocated packaged model-login icons load without the developer build tree|PASS|PASS|一致|
|remote job digest mismatch fails closed|PASS|PASS|一致|
|remote runner exposes target readiness publication|PASS|PASS|一致|
|remote wire document and projection carry assistant identity without changing generalProjectID|PASS|PASS|一致|
|remote-runner result exposes provider-observed exact-model evidence|PASS|PASS|一致|
|remote: begin_connect/cancel_connect/connect_status signed with expires_at, epoch, attempt and owner; no code in the polled status; bare start_pairing retired|PASS|PASS|一致|
|removed field after input events cannot submit its old form|PASS|PASS|一致|
|render and plan are deterministic even when registry entries are reordered|PASS|PASS|一致|
|renderer failure is not cleared by resource activity|PASS|PASS|一致|
|repository is selectable fixed text; feedback defaults cannot redirect App updates|PASS|PASS|一致|
|repository without a target active head is omitted from readiness digest|PASS|PASS|一致|
|reset dialogs: aria-hidden is not proof of a hidden skeleton|PASS|PASS|一致|
|reset dialogs: display-contents is not proof of a hidden skeleton|PASS|PASS|一致|
|reset dialogs: inert is not proof of a hidden skeleton|PASS|PASS|一致|
|reset dialogs: native open/modal or unknown getters block even with display none|PASS|PASS|一致|
|reset dialogs: only proven hidden nodes are ignored, including multiple dialogs and query failures|PASS|PASS|一致|
|reset dialogs: opacity is not proof of a hidden skeleton|PASS|PASS|一致|
|reset dialogs: style-error is not proof of a hidden skeleton|PASS|PASS|一致|
|reset dialogs: zero-rect is not proof of a hidden skeleton|PASS|PASS|一致|
|reset exact DOM: attachment cannot authorize clearing|PASS|PASS|一致|
|reset exact DOM: children-getter cannot authorize clearing|PASS|PASS|一致|
|reset exact DOM: double-br cannot authorize clearing|PASS|PASS|一致|
|reset exact DOM: empty with hidden skeleton supports new normal|PASS|PASS|一致|
|reset exact DOM: empty with hidden skeleton supports new personalized|PASS|PASS|一致|
|reset exact DOM: noneditable cannot authorize clearing|PASS|PASS|一致|
|reset exact DOM: p_br with hidden skeleton supports new normal|PASS|PASS|一致|
|reset exact DOM: p_br with hidden skeleton supports new personalized|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+20|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+200b|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+9|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+a|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+a0|PASS|PASS|一致|
|reset exact DOM: preserves real text node U+feff|PASS|PASS|一致|
|reset exact DOM: text-getter cannot authorize clearing|PASS|PASS|一致|
|reset exact DOM: textarea whitespace and non-text extra structure are preserved|PASS|PASS|一致|
|reset rechecks: focus cannot restore a draft, attachment or active dialog before insertion|PASS|PASS|一致|
|reset rechecks: observed dialog latches invalid after it becomes hidden again|PASS|PASS|一致|
|resident Codex sidecar binds model, effort and speed to each queued turn|PASS|PASS|一致|
|resolver precedence, whitespace, tilde expansion and canonical child paths|PASS|PASS|一致|
|restoration OCR joins line wraps while preserving spaces and tabs|PASS|PASS|一致|
|result parser rejects missing summaries, duplicate identities and incomplete totals|PASS|PASS|一致|
|retirement failure removes the staged store and preserves live state|PASS|PASS|一致|
|return timings inside the host: closing, main-window commands, 拿回來 and fullscreen give the page back first, then tell the borrower|PASS|PASS|一致|
|reuse Grok hash mismatch fails closed without executing the trap runtime|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse Grok missing pins, symlinks, and bundle escapes fail closed without execution|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse accepts a /tmp alias in declared receipt path without changing any bytes|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse actual model-runtime resolution copies only signed pinned Grok bytes without probing them|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse preserves a receipt-pinned Chromium engine when --enable-cef is omitted|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse rejects a genuinely different declared bundle path without changing the slot|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse rejects an unapproved WebKit to Chromium engine migration|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|reuse rejects an unpinned legacy receipt without explicit Chromium migration|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|review fixes: LRU by last read, evicted threads written back, slim document with its own cap, removal archives the copy|PASS|PASS|一致|
|review fixes: Pod commands only run on chatgpt.com; same-origin downloads are no-store; diag routes are categories only|PASS|PASS|一致|
|review fixes: a send that stays in Work is not sent; a Request-object send is still rewritten|PASS|PASS|一致|
|review fixes: text before a handoff is not completion; polling ignores the previous turn's finished answer|PASS|PASS|一致|
|review fixes: turn results follow the turn, not the current view; photo promises always clean up; cache purge refuses symlinks|PASS|PASS|一致|
|review: pre-planted hard links are refused before any command, git diff or submit; scratch is prepared without following links|PASS|PASS|一致|
|rg absence falls back to real grep -rn with array args, exclusions and matching parity|PASS|PASS|一致|
|role PRIMARY: save locally with secondary notice, never commit or stage|PASS|PASS|一致|
|role invalid: save locally with secondary notice, never commit or stage|PASS|PASS|一致|
|role null: save locally with secondary notice, never commit or stage|PASS|PASS|一致|
|role secondary: save locally with secondary notice, never commit or stage|PASS|PASS|一致|
|rollback failure restores the complete applied after-state and emits authority-bound failure receipt|PASS|PASS|一致|
|rollback of newly created presets removes targets but keeps a recoverable archive|PASS|PASS|一致|
|rollback recovery failure is explicit, fail-closed, and authority-bound|PASS|PASS|一致|
|rollback rejects a tampered apply receipt before touching targets|PASS|PASS|一致|
|rollback restores prior managed bytes and archives the after-state|PASS|PASS|一致|
|root-admin enrollment is fixed-root, interactive, create-only, and enrollment-only|PASS|PASS|一致|
|route diagnostics: UUID tail mismatch and tick/response callers remain fail-closed|PASS|PASS|一致|
|route diagnostics: direct/root successes and conflicting original IDs retain existing decisions|PASS|PASS|一致|
|route diagnostics: navigation sources stay distinct; observed need not equal current, and native empty remains rejected|PASS|PASS|一致|
|route diagnostics: original ID binds before mid-stream route revoke, unlike revoke before ID parsing|PASS|PASS|一致|
|route diagnostics: pure shape function preserves empty/encoded/trailing segments and only emits bounded structure|PASS|PASS|一致|
|route diagnostics: same-turn ID records ignore non-authoritative and stale turns, preserve first binding, and reset on new proof|PASS|PASS|一致|
|route diagnostics: transient empty/non-UUID route precedes original ID; first revoke survives return and denied follow-up|PASS|PASS|一致|
|rpath directory and broken symlink cannot become file permissions|PASS|PASS|一致|
|run helper: a hanging child fails with timeout and signal diagnostics|PASS|PASS|一致|
|run helper: codesign has a 30s ceiling and other commands have a 120s ceiling|PASS|PASS|一致|
|run helper: nonzero exit, signal and missing command fail with explicit diagnostics|PASS|PASS|一致|
|run helper: success preserves stdout and supplied environment|PASS|PASS|一致|
|runpath order resolves only the first existing exact file, not all candidate directories|PASS|PASS|一致|
|runtime (production code, engine double): lends only awake, non-sensitive Browser work space tabs; 拿回來 tells the tent|PASS|PASS|一致|
|runtime default remains runtime; project fallback uses entrance repo docs|PASS|PASS|一致|
|runtime digest excludes any-depth .git only and keeps other dotfiles|PASS|PASS|一致|
|runtime digest helper matches portable skillet snapshot contract|PASS|PASS|一致|
|runtime failures are not converted into successful typing|PASS|PASS|一致|
|runtime fallback fails closed without an explicit authorization|PASS|PASS|一致|
|runtime fallback rejects a stale or wrong-device authorization|PASS|PASS|一致|
|runtime replaces stub, shared MCP wiring and caller-owned policy remain fenced|PASS|PASS|一致|
|same-slot preflight rejects a second top-level App|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|same-slot storage is repo-owned and insufficient build space fails closed|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|same-thread loops refresh preserves contracts across presentation-only differences|PASS|PASS|一致|
|sanitized build environment rejects ambient PATH toolchain shims|PASS|PASS|一致|
|scan exposes the actual connected detail state for migration instead of assuming installed means connected|PASS|PASS|一致|
|scan follows the visible Apps self-created tab and includes unfinished entries|PASS|PASS|一致|
|scan recognizes the lead's manual link (~ or absolute, entry itself a symlink)|PASS|PASS|一致|
|schema-aware owner verification is closed-world and raw clear is absent|PASS|PASS|一致|
|scratch roots are unique, outside the checkout and do not share writable state|PASS|PASS|一致|
|secondary + reachable primary: TATWO assistant uses the primary thread through the remote engine|PASS|PASS|一致|
|secondary protocol: commit → target → pinned fetch → check tree → merge → pushPinned inbox → signed receive|PASS|PASS|一致|
|secondary: pinned host key clone from the primary, else local copy waiting for sync|PASS|PASS|一致|
|secrets checked at the sync boundary (both sending and receiving), including history|PASS|PASS|一致|
|security failure is not cleared by resource activity|PASS|PASS|一致|
|security gates unchanged: sensitive page, full access for self, selected local chat (baseline selfOperated exception kept)|PASS|PASS|一致|
|self-build defaults to a pin-exact plan, without creating files or calling network/build tools|PASS|PASS|一致|
|self-test (w184browser) covers the sidebar, toolbar and search with counterexamples and side-by-side PNG evidence; isolated, fakes only, no personal data|PASS|PASS|一致|
|self-test entry and required checks|PASS|PASS|一致|
|self-test entry, isolation and required checks|PASS|PASS|一致|
|self-test w183browser is registered, DEBUG-only, isolated, fakes only, and never reports a fake CEF pass|PASS|PASS|一致|
|self-test w183build is registered, isolated, and covers every required scenario|PASS|PASS|一致|
|self-test w183connect is registered, DEBUG-only, isolated, and never reports a fake CEF pass|PASS|PASS|一致|
|self-test w184browser is registered, DEBUG-only, isolated, fakes only, with counterexamples for every capture rule and PNG evidence|PASS|PASS|一致|
|selftest extracts, merges, and refuses secrets|PASS|PASS|一致|
|selftest validates source truth without live apply|PASS|PASS|一致|
|selftest: missing W187_TEST_ROOT never starts normal App|PASS|PASS|一致|
|selftests are registered and write harness uses fixture transports|PASS|PASS|一致|
|send-01 func send() does not launch synchronous login processes|PASS|PASS|一致|
|send-01 func sendFromDM( does not launch synchronous login processes|PASS|PASS|一致|
|send-01 init(environment: [String: String] does not launch synchronous login processes|PASS|PASS|一致|
|send-01 private func sendLoginStatus( does not launch synchronous login processes|PASS|PASS|一致|
|send-01 private func sendToLocalAssistant( does not launch synchronous login processes|PASS|PASS|一致|
|send-01 private func startPRContribution( does not launch synchronous login processes|PASS|PASS|一致|
|send-04 strict failure preserves original before record recovery|PASS|PASS|一致|
|send-05 running lists own current work; same-revision polls still notify toolbar|PASS|PASS|一致|
|send-08 real queued stop emits notSubmitted before finishing its stream|PASS|PASS|一致|
|send-09/F1 forced stop settles delivery before disconnecting sidecar events|PASS|PASS|一致|
|send-11 host refusal codes and remote refresh keep diagnostics visible|PASS|PASS|一致|
|send-12/F4 mention selection preserves text and requires explicit keyboard selection|PASS|PASS|一致|
|send: replaces a restored draft inside the composer; fails loudly when it cannot type or has no composer|PASS|PASS|一致|
|sendFromDM targets an explicit local thread and never touches Coder selection or draft|PASS|PASS|一致|
|sends to the primary wait for its receipt: draft kept until then, blocked meanwhile, failures explained|PASS|PASS|一致|
|sensitive associated labels and disabled controls remain explicit|PASS|PASS|一致|
|session candidates exclude the assistant, archived and remote rooms; sub-threads hang under their parent|PASS|PASS|一致|
|session is memory-only, handles full-text replacement and needsLogin without opening UI|PASS|PASS|一致|
|settings action is a glass chip and permission checks are gated by the keyboard toggle|PASS|PASS|一致|
|settings adds one row with consent API, live HTTPS query and visible failures|PASS|PASS|一致|
|settings builder callback does not switch to Bot|PASS|PASS|一致|
|settings.json: only the autoMemoryDirectory key is merged, never re-serialized|PASS|PASS|一致|
|settings: a 私訊鈕 block in an existing tab (not OS page / setup guide), glass chips, per-key disable controls|PASS|PASS|一致|
|setup command Seatbelt profile: deny-by-default writes, exec, fork, local services and sockets; only the setup home writable|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|setup guard: stdin EOF or SIGTERM kills the child and deletes leftovers; a normal exit keeps them and passes the code|PASS|PASS|一致|
|shared composer pieces: stop button and drawer copy Coder exactly; Coder callers unchanged|PASS|PASS|一致|
|shared runtime retains the native host and keys background states before active navigation|PASS|PASS|一致|
|shared toolbar retains address, explicit history/reload, focus and escape|PASS|PASS|一致|
|shell directory and link mutation primitives are discovered|PASS|PASS|一致|
|shell renders shared content and every interrupt caller preserves the Bool guard|PASS|PASS|一致|
|shipped OS templates match the repository documents, not an older constitution|PASS|PASS|一致|
|sidebar (W184 G2d): the DM sidebar IS the main window's BrowserWorkSpaceSidebarList (borrowed; same order, headers and space-name place) — hover-revealed glass, full height, flush left, no handle|PASS|PASS|一致|
|sidebar empty state and local project actions use existing controls|PASS|PASS|一致|
|sidebar geometry and commands stay on the outer container; page actions stay on the session store|PASS|PASS|一致|
|sidebar observes shared update state and retains settings integration|PASS|PASS|一致|
|sidebar rows come from the tab enum (same source as the header chips); team disabled (memory opened by E1)|PASS|PASS|一致|
|sidebar: offline section still lists the last synced projects and threads, dimmed, with the last sync time|PASS|PASS|一致|
|sidecar 啟動環境拿掉被勾那家的金鑰；GBrain 不帶被勾那家的金鑰|PASS|PASS|一致|
|sign identity selector: an explicit full SHA selects the matching second valid identity|PASS|PASS|一致|
|sign identity selector: duplicate matches fail closed rather than choosing an ambiguous entry|PASS|PASS|一致|
|sign identity selector: malformed or empty pins fail instead of using the first identity|PASS|PASS|一致|
|sign identity selector: missing pins, warning/name hashes and invalid entries fail closed|PASS|PASS|一致|
|sign identity selector: no pin preserves first identity and absent-certificate behavior|PASS|PASS|一致|
|signed calls to the primary are serialized: sequence numbers arrive in order|PASS|PASS|一致|
|signed device row retains native offline status, retry and cancel controls in both appearances|PASS|PASS|一致|
|simplified pairing and cloud screenshot disclosure are present|PASS|PASS|一致|
|single control shares navigation hit-size and icon tokens|PASS|PASS|一致|
|skill scans publish on the main actor, before waiting for MCP, using one refresh path|PASS|PASS|一致|
|skillet only dispatched index, anchored openat, no symlinks/hardlinks/nonregular/secret/oversize/private discovery|PASS|PASS|一致|
|skillet-md selftest keeps vendor SKILL.md and refuses unsafe paths|PASS|PASS|一致|
|slash events depend on input eligibility, not catalog matches; pairing only observes success|PASS|PASS|一致|
|snapshot deadline and mount-bound stale-request cancellation remain unchanged|PASS|PASS|一致|
|snapshot digest follows the portable UTF-8 byte ordering contract|PASS|PASS|一致|
|snapshot dispatch wakes an idle CEF pump after command and timeout registration|PASS|PASS|一致|
|snapshot result remains tied to browser, navigation generation and committed URL|PASS|PASS|一致|
|snapshot uses the existing host kick rather than the cancellable vendor timer|PASS|PASS|一致|
|source changed after validation is not promoted into the cache|PASS|PASS|一致|
|source guards: progress, guarded action, verified cache, active helper, zero exits|PASS|PASS|一致|
|source prose uses the existing timeline expansion, never raw thinking|PASS|PASS|一致|
|source root must be absolute and readable|PASS|PASS|一致|
|source snapshot does not fan out per-file git hash-object stdin subprocesses|PASS|PASS|一致|
|source snapshot rejects Git LFS attributes|PASS|PASS|一致|
|source snapshot rejects Git LFS pointer|PASS|PASS|一致|
|source snapshot rejects Git submodules|PASS|PASS|一致|
|space name next to the traffic lights is bold text without a chevron|PASS|PASS|一致|
|space title is text only, while native Menu remains accessible and functional|PASS|PASS|一致|
|spawn failure cleans only owned prompt storage and preserves the source image|PASS|PASS|一致|
|staged probes use exact source bytes and isolate script-derived build output|PASS|PASS|一致|
|staged-resource drift fails closed against its captured filesystem manifest|PASS|PASS|一致|
|staging and rollback paths are redacted from refresh diagnostics|PASS|PASS|一致|
|staging build rejects an invalid App MCP port before Swift build|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|staging build rejects an occupied App MCP port before Swift build|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|staging build rejects external mutable runtime before Swift build|PASS|PASS|一致|
|staging bundle records one App MCP port in launch environment and receipt|PASS|PASS|一致|
|staging preserves all six required inputs and excludes local or unknown files|PASS|PASS|一致|
|stale newest readback fails the bounded max-age gate|PASS|PASS|一致|
|stale or mismatched active revision is explicit fail-closed status|PASS|PASS|一致|
|stale reuse plist Chat workdir fails closed without an explicit current-root override|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|stale steering target is rejected and a mismatched reply is reported as unknown|PASS|PASS|一致|
|stale target and mismatched authorization both fail before mutation|PASS|PASS|一致|
|start page has only the central search; submitted pages expose the address bar|PASS|PASS|一致|
|start page submission also navigates a previously cached blank CEF tab|PASS|PASS|一致|
|status drawer is quiet unless there is something to say (Coder 09-11 ruling)|PASS|PASS|一致|
|status page: wording, identifiers, glass chips only, approvals only via Island, open in Coder|PASS|PASS|一致|
|status: @Published last sync / pending / conflicts / one-line error; glass row in 設定 › OS › 記憶; started at launch|PASS|PASS|一致|
|steering before native ID waits for start event and is sent exactly once|PASS|PASS|一致|
|stop before boot drops prior sends, but accepts an explicit later send|PASS|PASS|一致|
|stop before start cancels pending steering without replay|PASS|PASS|一致|
|stop declines pending and late approvals rather than authorizing more work|PASS|PASS|一致|
|stop during turn/start waits for ID and sends exactly one interrupt|PASS|PASS|一致|
|stop pauses active Goal before interrupt and catches a continuation during pause|PASS|PASS|一致|
|stop verification is machine-readable and harmless validation errors preserve consent|PASS|PASS|一致|
|store and logic: queue + move log in live/, never touch project folders, archive not delete|PASS|PASS|一致|
|store keeps per-target drafts, remembers the last target, and has a default-on master switch|PASS|PASS|一致|
|structured reporter preserves parent names and same-title occurrences|PASS|PASS|一致|
|submitted callback is artifact-scoped and incomplete or busy canvases cannot submit|PASS|PASS|一致|
|submitted steering survives stop with ack after terminal|PASS|PASS|一致|
|submitted steering survives stop with ack before terminal|PASS|PASS|一致|
|success = this attempt's grant plus that grant's first /mcp; cancel and success have one terminal state|PASS|PASS|一致|
|successful dispatch persists mode exit before sending, failed acceptance does not exit|PASS|PASS|一致|
|swiftc WorkspaceModeRows partitions 1 through 8 and preserves every item|PASS|PASS|一致|
|swiftc executes real session projection + registry + runtime: ownership, commands, popup, stale/invalid selection|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|swiftc fixture projects isolated registry tabs and import state with network and file writes denied|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|swiftc production liveness, real fake configs, timeout, cache, builtins, audit and safe removal|PASS|PASS|一致|
|swiftc production runtime: snapshots, limits, effect/policy matrices, consent, stale, audit, cancellation|PASS|PASS|一致|
|swiftc real notice + compatibility UI + presenter: FIFO, timeout, fallback and cancellation|PASS|PASS|一致|
|swiftc registry fixture: ownership, adapters, durability, debounce and migration|PASS|PASS|一致|
|swiftc typechecks complete design and real wrapping picker against isolated signatures|PASS|PASS|一致|
|swiftc: backend timestamps and actual diagnostics refresh stop when page task cancels|PASS|PASS|一致|
|swiftc: existing ComputerUseSession XCTest suite without building or launching the App|SKIP|SKIP|一致|
|swiftc: human/agent matrix, private navigation, permissions, settings persistence and W44 alias|PASS|PASS|一致|
|swiftc: native consent and complete download lifecycle without app UI|PASS|PASS|一致|
|swiftc: production policy matrix and session epoch lifetime|PASS|PASS|一致|
|swiftc: real ring, redaction, helper roles/process sampling, audit tail, throttle and report|PASS|PASS|一致|
|swiftc: settings round-trip, engine URLs, policy reload, metadata and Netscape export|PASS|PASS|一致|
|swiftc: sleep environment override is finite/positive and keeps selected tabs awake|PASS|PASS|一致|
|system payload preparation explicitly blocks publication when refresh fails|PASS|PASS|一致|
|tab skeleton: one enum and store, host switches pages, ChatPageModel untouched|PASS|PASS|一致|
|tabs in the sidebar: tap a row = switch, × = close (a flow tab still cancels its flow), 新分頁 = DMBrowser.newTab; 📌 Pinned rows open in the DM|PASS|PASS|一致|
|tabs never vanish on their own: box closed or hidden = page taken off screen, not destroyed; done = labelled; flow end = caller closes; master switch off = all close|PASS|PASS|一致|
|tatwo code-health MCP|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|tatwo direct gateway chat unit (mock gateway)|PASS|PASS|一致|
|tatwo domain coordinator local host|PASS|PASS|一致|
|tatwo ultrawork MCP gateway|PASS|PASS|一致|
|tent: no top bar, the whole box is GlobalDMTentContent (room E fills it with the video pane)|PASS|PASS|一致|
|test-only CEF verification and failure injection reject outside, sibling-prefix and symlink escapes before writes|PASS|PASS|一致|
|tests/agent-kernel-driver-k3-source-contract.test.mjs|PASS|PASS|一致|
|tests/g2c-realistic-corpus-source-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-app-server-same-thread-smoke.test.mjs|PASS|PASS|一致|
|tests/tatwo-contract-loops-executor.test.mjs|PASS|PASS|一致|
|tests/tatwo-domain-authority-canary.test.mjs|PASS|PASS|一致|
|tests/tatwo-domain-coordinator.test.mjs|PASS|PASS|一致|
|tests/tatwo-fusion-candidate-bundle-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-local-validation-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-local-validation-pair.test.mjs|PASS|PASS|一致|
|tests/tatwo-main-app-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-model-gateway-continuation-route-boundaries.test.mjs|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|tests/tatwo-model-gateway-fixture-isolation.test.mjs|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|tests/tatwo-model-route-soak.test.mjs|PASS|PASS|一致|
|tests/tatwo-os-dispatch-finalize-mcp.test.mjs|PASS|PASS|一致|
|tests/tatwo-same-thread-evidence.test.mjs|PASS|PASS|一致|
|tests/tatwo-session-start-cli-source-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-signed-release-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-sparkle-bundle-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-static-audit-migration-core.test.mjs|PASS|PASS|一致|
|tests/tatwo-static-audit-migration-pages.test.mjs|PASS|PASS|一致|
|tests/tatwo-static-audit-source-contract.test.mjs|PASS|PASS|一致|
|tests/tatwo-test-shard.test.mjs|PASS|PASS|一致|
|tests/tatwo-three-plane-static-gate.test.mjs|PASS|PASS|一致|
|tests/tatwo-user-data-migration.test.mjs|PASS|PASS|一致|
|text actions are the App glass chip; selection is the only accent|PASS|PASS|一致|
|text-only remains -p; native model/rules and session resume are preserved|PASS|PASS|一致|
|textarea and empty replacement remain supported|PASS|PASS|一致|
|the bare seed never replaces a curated skillet, and linked wrappers stay links|PASS|PASS|一致|
|the first message carries the context like E3 seedPrompt (data, not instructions), only the first time per engine|PASS|PASS|一致|
|the sidebar never covers the connect card buttons; it gets its own clicks over the CEF page only while it is out|PASS|PASS|一致|
|the three actions queue offline and can be cancelled|PASS|PASS|一致|
|three-round comparison distinguishes persistent, flipping, missing and cancelled tests|PASS|PASS|一致|
|timeout, mktemp failure and curl failure finish without restart loops|PASS|PASS|一致|
|timeouts and missing roots expose partial coverage rather than pretending completion|PASS|PASS|一致|
|timing with the forms (room AB): leave the tent before the animation, enter after it; hand-offs wait a beat|PASS|PASS|一致|
|timing: every 60 s, a change triggers within 10 s, background queue, never git on the main thread|PASS|PASS|一致|
|toolbar (W184 G2d): the Browser space row — sidebar button, back, forward, reload, address \| ⋯, translate, extensions, notes; hover-revealed glass across the Browser|PASS|PASS|一致|
|toolbar consumes real layout height above native page, including empty/session spaces|PASS|PASS|一致|
|transaction pins and rechecks the exact state-root preflight before mutation|PASS|PASS|一致|
|transient failures are actionable and navigation still uses human policy|PASS|PASS|一致|
|transparent CSS canvas keeps black labels readable on the actual white document canvas|PASS|PASS|一致|
|typing (toolbar address and centered search): the page never steals the keyboard while typing; Esc ends typing only|PASS|PASS|一致|
|unchanged source reuses the cache; changed source builds a new digest|PASS|PASS|一致|
|uncoordinated live-store mutation aborts activation without losing the write|PASS|PASS|一致|
|unfinished self-created connector is included alongside installed entries without pressing Create|PASS|PASS|一致|
|unify archives a proposal without rewriting curated skillet.md or vendor skills|PASS|PASS|一致|
|unify merges inbox into host and never writes the secondary store|PASS|PASS|一致|
|unknown boot Goal waits for one read then pauses before interrupting autonomous work|PASS|PASS|一致|
|unknown permission mode is rejected before SDK query|PASS|PASS|一致|
|unreachable primary + all local engines disabled: one plain note, no send, draft kept|PASS|PASS|一致|
|unresolved @rpath fails closed even if a same-name library exists beside node|PASS|PASS|一致|
|unsupported Goal API is unavailable rather than silently treated as no Goal|PASS|PASS|一致|
|unsupported atomic swap uses the compensating directory exchange|PASS|PASS|一致|
|update card always shows installed bundle version/build and the available version arrow|PASS|PASS|一致|
|update card shares the guarded update action and keeps the terminal fallback|PASS|PASS|一致|
|updater reuses install.sh from the same public repository for signing and replacement after prefetch|PASS|PASS|一致|
|upgrade check Studio-client-only: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check Studio-pinned: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check Studio-unpinned: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check book: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check clock: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check executes before every launch hook and its transitive source contains no write operation|PASS|PASS|一致|
|upgrade check mini: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check missing-live: exact private output and no fixture writes|PASS|PASS|一致|
|upgrade check unknown: exact private output and no fixture writes|PASS|PASS|一致|
|v2 §2 CSRF：缺 cookie、cookie 不符、錯 Origin、沒有 Origin、Origin: null 沒標同源、Sec-Fetch-Site 跨站、表單 token 不符都拒；這些都沒送到 App|PASS|PASS|一致|
|v2 §2 IP 清單四種失效（關口實跑）：沒有可信清單、清單有一筆壞掉、過期 7 天、時間在未來 → 全部端點（含 /authorize）403；換回好清單就恢復|PASS|PASS|一致|
|v2 §2 IP 清單政策（關口讀檔）：沒有清單、空、有一筆不合法或太寬、過期 7 天、時間在未來＝全拒；捷徑不跟隨|PASS|PASS|一致|
|v2 §2 端點矩陣：metadata／register／token／mcp 只收 OpenAI IP；瀏覽器 IP 只到得了 /authorize；方法不對 405；其他 404；沒有管理端點|PASS|PASS|一致|
|v2 §3／T15 配對窗口：瀏覽器（非 OpenAI IP）打得到 /authorize，但 App 沒開窗口就請使用者先在 TATWO 按開始配對；已有一筆待配對也不開|PASS|PASS|一致|
|v2 §3／v3 V15 完整配對：註冊 → 授權頁顯示交易編號與回呼網域、文案「授權這筆連線」 → 錯碼 → 對碼 → 302 回 callback → token → refresh 輪替、重用即撤銷該 grant|PASS|PASS|一致|
|v3 V12 request_id：同一個 session、同一個 JSON-RPC id → 同一個 request_id（HTTP 重試認得出來）；不同 id 不同；tools/call 沒有 session＝400、認不得的 session（亂填、別的 grant、過期）＝404，都不送 App|PASS|PASS|一致|
|v3 V12 跨重啟去重：App 已經執行、回應沒送到、關口重開 → 客戶端拿原 session、原 id 重試，送給 App 的 request_id 一樣（App 認得出是同一件事）|PASS|PASS|一致|
|v3 V17 配對碼：8 碼、23456789ABCDEFGHJKLMNPQRSTUVWXYZ、不分大小寫；格式不對直接擋（不送 App、不浪費次數）|PASS|PASS|一致|
|v3 V18 配對次數：每個來源各自有額度（IPv6 以 /64 算）、全關口另有上限|PASS|PASS|一致|
|v3 V8／T13／T10 App 端服務：兄弟行程、啟動與退出順序、CLOEXEC_DEFAULT、cloudflared 獨立 HOME＋明確 --config＋--no-autoupdate、token 只走 0600 檔、自測／staging 不啟動|PASS|PASS|一致|
|v6 import is a seven-source, five-choice local sheet with profile and Arc restrictions|PASS|PASS|一致|
|v6 sidebar has five ordered sections, white selection and no chat or search pane|PASS|PASS|一致|
|verified local copy is hash-isolated and receipt records real source|PASS|PASS|一致|
|verify_installed_readback rejects installed embedded provenance tamper|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|versioned frameworks follow real version directories, not Current symlink ancestors|PASS|PASS|一致|
|versioned sync catalog validates|PASS|PASS|一致|
|visibleModes keeps custom IDs and gates Browser only|PASS|PASS|一致|
|voice: stopping while connecting voids the late start and ends the page session; the Pod auto-ends voice that starts after a stop|PASS|PASS|一致|
|w179remote native cleanup behavior|PASS|PASS|一致|
|w179ui self-test entry covers every group|PASS|PASS|一致|
|w180classify self-test entry covers every acceptance item|PASS|PASS|一致|
|w180dm native cleanup behavior|PASS|PASS|一致|
|w180leftovers self-test entry covers the clone picker and the thread source|PASS|PASS|一致|
|w180overview self-test entry covers every step|PASS|PASS|一致|
|w182assistoffline native cleanup behavior|PASS|PASS|一致|
|w182offline native cleanup behavior|PASS|PASS|一致|
|w185 fixture node cleanup: Homebrew node|PASS|PASS|一致|
|w185 fixture node cleanup: assertion failure|PASS|PASS|一致|
|w185 fixture node cleanup: copy exception|PASS|PASS|一致|
|w185 fixture node cleanup: spawn exception|PASS|PASS|一致|
|w185 fixture node cleanup: success|PASS|PASS|一致|
|w185 fixture node cleanup: supplied node|PASS|PASS|一致|
|w185tap exercises ChatPageModel.send/stop, captures CLI fallback and exports native UI evidence|PASS|PASS|一致|
|w185tap native cleanup behavior|PASS|PASS|一致|
|w197dots native cleanup behavior|PASS|PASS|一致|
|w198dispatch native cleanup behavior|PASS|PASS|一致|
|w199quiet native cleanup behavior|PASS|PASS|一致|
|w202perf native cleanup behavior|PASS|PASS|一致|
|white text on transparent white canvas stays quarantined, not falsely admitted against transparent black|PASS|PASS|一致|
|window close asks only while work is running; app terminate and composer stop always ask|PASS|PASS|一致|
|wire: allowlisted proposal fields only, merged into the overview allowlist|PASS|PASS|一致|
|workspace design projects registry data; W47 transport is confined to its surface|PASS|PASS|一致|
|workspace mounts actual human CEF only after access; keeps one persistent pool across switches|PASS|PASS|一致|
|workspace picker wraps without horizontal scrolling and preserves font table and chip geometry|PASS|PASS|一致|
|wrapper selftest is executable through bash|PASS|PASS|一致|
|⌘T：看著網頁時不換頁、搜尋欄空白、送出開成新分頁；Esc／失焦取消|PASS|PASS|一致|
|一個判斷：送出、原生目標、派工退回都走 EngineDisableStore.sendBlockReason；沒勾先回 nil|PASS|PASS|一致|
|使用者 2026-09-19：Island 的畫法就是原版（mini 上那個），只多加自定義滑軌——不准有別的補丁|PASS|PASS|一致|
|使用者 2026-09-19：拖尺寸滑桿時真的 Island 要即時變化|PASS|PASS|一致|
|側欄拖拽：釘選／取消釘選／移出書籤／移出珍藏／存進資料夾|PASS|PASS|一致|
|共用元件存在：內距 14、區塊間距 12、標題 .headline、副標 .caption＋secondary|PASS|PASS|一致|
|分頁列與珍藏格不是 Button（Button 會吃掉 mouse-down，拖曳起不來）；輔助使用仍是按鈕|PASS|PASS|一致|
|列車 103 收尾：W107 鑰匙圈不在主執行緒讀、W108 空間不足不留大檔、刪討論串清分頁組、Session space 共用導覽|PASS|PASS|一致|
|判斷探針（swiftc 單獨編譯真的判斷檔）：訂閱放行、API 金鑰與判斷不出來擋、沒勾照舊、環境與 GBrain 不帶金鑰|PASS|PASS|一致|
|十一頁都改用同一組標題列與內距（Space 本來就是標準）|PASS|PASS|一致|
|原生通道：只給使用者自己的分頁；逾時會結束；回呼表不放進 C++ 狀態結構|PASS|PASS|一致|
|在這台接著聊: a new local thread (banner first, copied messages), same-name project or a new one in this home, never 聊天 unless it was|PASS|PASS|一致|
|外框只有一個尺寸：780×560，沒有哪一頁自己撐大|PASS|PASS|一致|
|審查 R2b 斷線收尾：等 App 驗 token 時客戶端斷線，不會永久佔住 grant 名額（之後同一個 grant 照常，不會一直 429）|PASS|PASS|一致|
|審查 R2b 標頭：超過上限（100）＝431、不是默默截斷；CF-Connecting-IP／Host／Authorization 等重複＝400；剛好上限照常|PASS|PASS|一致|
|審查 R2b 連線數：大量連上卻只送一半標頭的連線，最多 maxConnections 條，其餘直接關；標頭期限到就全部收掉；之後照常服務|PASS|PASS|一致|
|審查 R2b 關口 Seatbelt 的 sysctl（原生探針實跑）：只開 Node 需要的；行程表、開機參數讀不到（主機名稱 uname 要用，只好開）；KERN_PROCARGS2（別的行程的環境變數）Seatbelt 擋不住＝殘餘，照實記錄|FAIL|FAIL|基準亦失敗（含環境／fixture 限制）；未修產品|
|審查 R2b 限流表有硬容量：滿了新來源一律拒絕、不配置狀態；舊來源照常；過期後清得掉；清表最多每秒一次|PASS|PASS|一致|
|審查 R2b 限流表（關口實跑）：很多來源打授權頁，表滿了新來源一律 429、已在表裡的照常|PASS|PASS|一致|
|審查 R2b／殘餘風險 V16 socket 冒充：socket 被換成別人的 listener、被刪、改名再改回來、上層資料夾被換掉，關口都會發現並以 socket_replaced／socket_missing 停下（結束碼 3）|PASS|PASS|一致|
|專案空間探針：預設全部、過濾、封存不刪、檔案壞掉退回全部且留 .bak|PASS|PASS|一致|
|引擎：一個 W180 E3 區塊；重複匯入打開舊的；不走「一般」；帶前情只限匯入的串|PASS|PASS|一致|
|打包：Engines/chatgpt-hands 進 Resources/chatgpt-hands、另起 inputs 行、沒有 supervisor、cloudflared 不打包、清理認得它|PASS|PASS|一致|
|授權頁的安全標頭與跳脫：CSP default-src none／form-action self（＋callback 來源）／frame-ancestors none、no-store、no-referrer、SameSite=Strict；參數不回顯|PASS|PASS|一致|
|接線：側欄入口、主畫面切換、接續走引擎自己的 resume、解析不在主執行緒|PASS|PASS|一致|
|接線：空殼移除、面板換成新元件、頂列鈕只在有變更時出現|PASS|PASS|一致|
|文字：不用 API 金鑰／可以用 API 金鑰／訂閱照用；只能看的說明；右鍵「移到其他設備…」|PASS|PASS|一致|
|框變窄之後，內容過長／過寬的頁面在框內捲動|PASS|PASS|一致|
|殘餘風險 V16：同一個 macOS 使用者的假 client 直接連關口 socket、偽造 OpenAI 的 CF-Connecting-IP 與 Host——打得到 metadata，但沒有配對與 token 拿不到任何工具|PASS|PASS|一致|
|沒有「完成」按鈕，殼上也沒有 ✕|PASS|PASS|一致|
|治理：匯入邏輯只讀、不連網；OS 內 AI 仍沒有讀歷史的 RPC；ChatPageModel 本體不動|PASS|PASS|一致|
|治理：清單只讀——不寫檔、不連網、資料庫只用唯讀開、SQL 只有 SELECT；OS 內 AI 沒有讀歷史的 RPC|PASS|PASS|一致|
|治理：讀取元件只讀，不寫檔、不刪檔、不連網、不進 RPC|PASS|PASS|一致|
|獨立 Browser：頂列是浮層、平時不在；紅綠燈與拖曳區一起讓開；工具列沒有「+」|PASS|PASS|一致|
|珍藏的分頁住在珍藏格子上、不列在下面；移出珍藏時分頁回到清單；書籤可就地改名|PASS|PASS|一致|
|畫面：兩顆來源 chip、左欄專案（則數＋最後活動）、中欄正式標題、右欄預覽；不再有「含非互動」「匯入 ≤」「Zero KB」|PASS|PASS|一致|
|畫面：匯入改用 W181 的匯入瀏覽器（玻璃 chip）；W110 閱讀器回到原樣、CLI 分頁不給匯入；切換器只在 Coder|PASS|PASS|一致|
|空間選單：寬度含內距（橘色不被裁）；標題中心釘在紅綠燈中心線|PASS|PASS|一致|
|空間：顏色欄位舊檔相容、刪除先封存、右鍵開 Dia 式選單|PASS|PASS|一致|
|總開關關閉時 Island 視窗不顯示、輪詢計時器與 notice host 都停掉|PASS|PASS|一致|
|總開關預設開啟，且沒有動過滑桿時尺寸與過去完全相同|PASS|PASS|一致|
|翻譯不能用時只變暗、不跳警示；量測用的 view 不吃滑鼠；HID 自測只在有輔助使用權限時送|PASS|PASS|一致|
|翻譯鈕在工具列、可手動按；網頁上不再有浮動圓鈕|PASS|PASS|一致|
|自測 .013 抓到的：分頁存成書籤要搬進書籤列；面板開著時隱形頂列不收；HID 點擊前先把 App 叫到前景|PASS|PASS|一致|
|自測入口與涵蓋；新檔沒有私人資料|PASS|PASS|一致|
|表格：每格在自己的欄裡換行（NSTextTable），不再用 tab 對欄|PASS|PASS|一致|
|設定 › OS: 記憶 block with one row per engine, glass chips, read-only text|PASS|PASS|一致|
|設定 › 開始使用: memory item right after the rules item, opens 設定 › OS|PASS|PASS|一致|
|設定相關檔案不再有各頁自訂大標與 22 內距|PASS|PASS|一致|
|設定：每一頁都關得掉（點外面空白＋Esc），殼上沒有 ✕|PASS|PASS|一致|
|讀取元件：清單、內容、壞行、截斷、子代理、接續條件|PASS|PASS|一致|
|讀取元件：非 git、乾淨、有變更（含未追蹤的新檔）各自回報正確|PASS|PASS|一致|
|起關口：socket 路徑被一般檔案占住就不刪、不起；設定檔不在就不起；錯誤碼不含路徑|PASS|PASS|一致|
|邏輯探針：Codex 專案順序與歸屬、Claude Code 標題順序、子代理與背景不列；Codex 沒開也讀得到；原檔（含 sqlite）不變|PASS|PASS|一致|
|邏輯探針：只留對話、上限生效、專案對應、前情包裝；原檔不變|PASS|PASS|一致|
|錯誤卡片：全 App 同一套液態表面、左緣對齊回覆文字欄|PASS|PASS|一致|
|關得掉：sheet 自己接 Esc／⌘W／取消，只關 sheet；第一下點擊就算數；掛在 TATWO 主視窗；自測走真的事件佇列|PASS|PASS|一致|
|頁面腳本：只動文字節點、跳過不該翻的區塊、可還原、不往 window 掛東西、不連網|PASS|PASS|一致|
|頭像：引擎回報的模型要存檔；換引擎不沿用上一家回報的模型；回覆中就標上|PASS|PASS|一致|
|額度：不替不認得的時窗取名字；原始回傳只有代號與數字|PASS|PASS|一致|
|額度：不認得、用量 0、沒有重置時間的時窗不畫成「剩 100%」|PASS|PASS|一致|
|黑瀏海與玻璃是兩個獨立的尺寸鍵，各自只驅動自己那一半的幾何|PASS|PASS|一致|
|點連結開的新分頁會切過去；⌘點擊才留在背景|PASS|PASS|一致|
