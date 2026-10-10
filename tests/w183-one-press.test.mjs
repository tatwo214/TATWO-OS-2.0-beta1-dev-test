// W183 R10：ChatGPT［連線］改成「按一下就好」——驗收 (a)–(g) 集中在這一份（施工單 H/briefs/w183-r10-one-press.md）。
// 使用者 09-29：「連線根本連不上 而且也根本不自動」「這邊要勾選也太怪 就要給他用了還要多一個勾選 chatgpt是日常最親的ai 沒有那麼多權限需要隔離」；
// 裁決：「I understand」與 8 碼由 TATWO 代做、只限 TATWO 自己開的那一頁；按［連線］＝同意；專案不用勾、不用到主機再核准。
// 取代的舊規矩：「勾風險、打 8 碼由使用者自己做」、contract §3b「首版不自動填碼」「TATWO 不代勾」、本機核准 ∩ 中央上限、卡上選專案。
// 靜態：原始碼契約；動態：檔案小幫手 fsop.mjs（子行程）、真的 git／find 跑金鑰類排除（跟 App 用的是同一張清單、同一個寫法）。
// 真的流程（假 Pod、假主機、真的 HandsAuth／HandsConnectHost）在 App 自測 w183connect／w183hands（lead-verify 在 mini 跑）；
// Pod 腳本的代勾（只量位置、只認那一格）在 tests/w183-connect.test.mjs 用 node:vm 跑真的腳本。
import test from 'node:test';
import { nativeW214 } from './w214-native-fixture.mjs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const read = (name) => fs.readFileSync(path.join(repo, name), 'utf8');
const swift = (name) => read(`App/Sources/Tatwo2/${name}`);
const code = (source) => source.replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^\n"]*$/gm, '');
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  return source.slice(from, to < 0 ? source.length : to);
};
const floors = swift('Facade/HandsFloors.swift');
const settings = swift('Facade/HandsSettings.swift');
const service = swift('Facade/HandsService.swift');
const sync = swift('Facade/HandsBuildSync.swift');
const rooms = swift('Facade/HandsRooms.swift');
const tools = swift('Facade/HandsTools.swift');
const host = swift('Facade/HandsConnectHost.swift');
const scope = swift('Facade/HandsConnectScope.swift');
const connect = swift('Facade/HandsConnect.swift');
const dmView = swift('New/HandsConnectDMView.swift');
const buildSection = swift('New/ChatGPTBuildSection.swift');
const buildModel = swift('Facade/HandsBuildModel.swift');
const pod = swift('TAP/ChatGPTConnectorPod.swift');
const tap = swift('TAP/ChatGPTTap.swift');
const r10 = swift('Facade/HandsConnectR10Acceptance.swift');
const scopeAcceptance = swift('Facade/HandsScopeAcceptance.swift');
const handsAcceptance = swift('Facade/HandsAcceptance.swift');
const fsopPath = path.join(repo, 'Engines/chatgpt-hands/fsop.mjs');
const fsopSource = read('Engines/chatgpt-hands/fsop.mjs');

// Swift 常數清單 → 陣列（只收字串字面值）。
const swiftList = (source, name) => {
  const body = source.match(new RegExp(`static let ${name}: \\[String\\] = \\[([\\s\\S]*?)\\]`))?.[1];
  assert.ok(body !== undefined, name);
  return [...body.matchAll(/"([^"\\]*)"/g)].map((m) => m[1]);
};
const jsList = (source, name) => {
  const body = source.match(new RegExp(`export const ${name} = \\[([\\s\\S]*?)\\];`))?.[1];
  assert.ok(body !== undefined, name);
  return [...body.matchAll(/'([^'\\]*)'/g)].map((m) => m[1]);
};
const SECRET = {
  names: swiftList(floors, 'names'),
  prefixes: swiftList(floors, 'prefixes'),
  suffixes: swiftList(floors, 'suffixes'),
  directories: swiftList(floors, 'directories'),
};

// ---------- (a) 中央設定即生效、不再 ∩ 本機 ----------

test('(a) the effective scope is the central setting (level) + every project on the host — no intersection with the local approval; revocation still immediate', () => {
  // 守：有效設定＝中央等級（夾在 0…2）＋全部專案；不讀本機的 allowed_project_ids、不跟本機等級取小。
  const centralized = between(settings, 'func centralized(by cap:', '/// 真正比對用的清單');
  assert.match(centralized, /var copy = self\s*if let cap \{ copy\.level = min\(max\(cap\.level, 0\), Self\.maxLevel\) \}\s*copy\.allProjects = true\s*return copy/);
  assert.doesNotMatch(code(centralized), /allowedProjectIDs|min\(level,/);
  assert.doesNotMatch(code(settings), /func capped\(by/, 'the old "local ∩ central cap" is gone');
  // 守：主機的每一道（工具清單、呼叫、授權、啟動、發布、回報）都照這一份。
  // W183 R11 第二輪（GPT-6 R11 審查 1）：有效設定照舊＝中央設定（不跟本機取小、不 ∩ 本機核准）；中央等級一變先把現有的 grant 封頂才生效
  //（levelGuard）。原本的一行寫法拆開了，守的一樣。
  const effectiveBody = between(service, 'func effectiveSettings() -> HandsSettings {', '/// 這台上一次生效的中央等級');
  assert.match(effectiveBody, /let effective = local\.centralized\(by: cap\)/);
  assert.match(effectiveBody, /if cap != nil \{ levelGuard\(central: effective\.level, local: local\.level\) \}\s*return effective/);
  assert.doesNotMatch(code(effectiveBody), /min\(|allowedProjectIDs/);
  assert.match(between(service, 'func admissionProblem(', '/// 給 HandsSandbox.run 的 admit'), /let current = effectiveSettings\(\)/);
  assert.match(host, /try offer\(settings: service\.effectiveSettings\(\), includeChoices: includeChoices\)/);
  // W183 R11 第二輪（GPT-6 R11 審查 1）：回報先拿有效設定（中央等級變了＝先封頂），中間讀 grant 的等級，再寫 report.level（照舊是有效設定的等級）。
  const reportBody = between(sync, 'let effective = service.effectiveSettings()', 'report.projectChoices = service.buildProjectChoices()');
  assert.match(reportBody, /report\.level = effective\.level/);
  // 守：reconcile 把中央等級寫進本機（收窄、放大都立刻），專案不再照中央清單收窄（本機欄位不是閘門，留著相容）。
  const reconcile = between(sync, 'struct HandsBuildReconciler', 'final class HandsBuildExecutor');
  assert.match(reconcile, /settings\.level = slice\.level\n/);
  assert.doesNotMatch(code(reconcile), /settings\.allowedProjectIDs =/);
  // 守：撤銷照舊立即——撤銷世代變大＝先作廢設定工作再全部撤銷；總開關關掉＝撤銷全部、收掉工作、鎖工作區。
  const revoke = between(reconcile, 'if slice.revocationGeneration > record.revocationGeneration {', '// 2.');
  assert.ok(revoke.indexOf('cancelSetup()') >= 0 && revoke.indexOf('cancelSetup()') < revoke.indexOf('updateSettings'));
  const update = between(service, 'func updateSettings(', 'func setEnabled(');
  assert.match(update, /if old\.enabled && !new\.enabled \{\s*revocationProblem = auth\.revokeAll\(reason: "switched_off"\)/);
  assert.match(update, /if new\.level < old\.level && new\.level < 2 \{\s*jobs\.cancel\(where: \{ _ in true \}, marksDirectory: marks\)/);
  // 守：面板的專案 chips 只顯示、「未生效」拿掉；等級照面板（中央設定）。
  assert.doesNotMatch(buildSection + buildModel, /notActive|未生效|projectsNone/);
  assert.match(between(buildModel, 'case .setProject:', 'case .connect(let device):'), /return \[\]/);
  // 自測（真的 HandsService／HandsAuth）有這兩條。
  for (const label of ['W183 R10 中央設定即生效', 'W183 R10 中央收窄照舊立刻生效']) assert.ok(scopeAcceptance.includes(label), label);
});

// ---------- (b) 專案全部可見、實盤類最多 L0 ----------

test('(b) every project is visible (new ones included); trading projects (one constant list) are at most L0 — L1/L2 tools are refused on the host', () => {
  // 守：同一份關鍵字、不分大小寫；設定資料夾名與真實路徑的家目錄以下每一段均用包含比對。
  assert.deepEqual(swiftList(floors, 'keywords'), ['實盤', '交易', 'trading', 'hermes', 'btc']);
  assert.match(floors, /static let maxLevel = 0/);
  assert.match(between(floors, 'static func isTrading(name: String, folder: String) -> Bool {', '\n    }'),
    /let texts = \[name\.lowercased\(\), \(folder as NSString\)\.lastPathComponent\.lowercased\(\)\] \+ tail\.split\(separator: "\/"\)\.map\(String\.init\)\s*return keywords\.contains \{ keyword in texts\.contains \{ \$0\.contains\(keyword\.lowercased\(\)\) \} \}/);
  // 守：全部可見＝這台全部看得到的專案（新專案自動加入），不是本機清單。
  assert.match(rooms, /let setting = settings\.allProjects \? host : Set\(settings\.allowedProjectIDs\)/);
  assert.match(swift('Facade/HandsService.swift'), /let records = current\.allProjects \? buildProjectRecords\(\) : projectRecords\(Set\(current\.allowedProjectIDs\)\)/);
  // 守：主機自己判斷（Coder 的名字、資料夾；不看 ChatGPT 傳的任何名字）；L1／L2 的工具在任何動作之前就拒（狀態與停工作的例外：不寫）。
  const floor = between(tools, 'static func floorProblem(', '// MARK: - 執行');
  assert.match(floor, /guard tool\.level > HandsTradingFloor\.maxLevel, !\["job_status", "job_output", "job_cancel"\]\.contains\(tool\.name\) else \{ return nil \}/);
  assert.match(floor, /service\.isTradingProject\(id\)/);
  assert.match(floor, /record\.grantID == grant\.grantID,\s*service\.isTradingProject\(record\.projectID\)/);
  assert.ok(tools.indexOf('if let refusal = floorProblem(') < tools.indexOf('func ok(_ text: String'), 'refused before anything runs');
  // 守：再兩道——開工作區本身、跑著的工作與最後一道（capProblem）。
  assert.match(rooms, /if project\.readOnly \{ throw HandsToolError\.invalid\(HandsTradingFloor\.refusal\) \}/);
  assert.match(service, /if level > HandsTradingFloor\.maxLevel, let projectID, isTradingCached\(projectID\) \{ return "project_read_only" \}/);
  // 守：面板與卡片標「只能看」，用同一個判斷。
  assert.match(floors, /var readOnlyFloor: Bool \{ HandsTradingFloor\.isTrading\(name: name, folder: folder\) \}/);
  assert.match(swift('New/HandsConnectDMView.swift'), /let count = offer\.scope\.readOnlyProjectIDs\.count[\s\S]{0,150}個交易類專案只能看/);
  assert.match(nativeW214(4), /W214 PASS N4.no-project-chips-or-detail-rows.true/);
  for (const label of ['W183 R10 新專案自動包含', 'W183 R10 底線 B：交易實盤類專案（名字或資料夾名）開工作區一律被拒',
    'W183 R10 底線 B：交易實盤類（名字含實盤、資料夾名含 hermes）L1、L2 的工作在最後一道也被擋']) {
    assert.ok(scopeAcceptance.includes(label), label);
  }
  assert.ok(handsAcceptance.includes('W183 R10 底線 B：交易實盤類專案（Coder 裡改名成含「實盤」的）'), 'tool-level self-test');
});

// ---------- (c) 金鑰類檔案在各等級、各工具都讀不到 ----------

test('(c) one key-file list: the App (Swift) and the file helper (fsop.mjs) carry the same names, prefixes, suffixes and folders', () => {
  assert.deepEqual(jsList(fsopSource, 'SECRET_NAMES'), SECRET.names);
  assert.deepEqual(jsList(fsopSource, 'SECRET_PREFIXES'), SECRET.prefixes);
  assert.deepEqual(jsList(fsopSource, 'SECRET_SUFFIXES'), SECRET.suffixes);
  assert.deepEqual(jsList(fsopSource, 'SECRET_DIRECTORIES'), SECRET.directories);
  // 守：施工單點名的都在（.env*、金鑰與憑證檔、id_*、*.pem、credentials*、鑰匙圈匯出）。
  for (const p of ['.env', 'credentials', 'id_']) assert.ok(SECRET.prefixes.includes(p), p);
  for (const s of ['.pem', '.key', '.p12', '.keychain', '.keychain-db']) assert.ok(SECRET.suffixes.includes(s), s);
  for (const d of ['.ssh', '.gnupg', '.aws']) assert.ok(SECRET.directories.includes(d), d);
  assert.match(floors, /let name = raw\.lowercased\(\)/, 'case-insensitive');
});

test('(c) every tool that reads blocks key files, at every level: project read/list/search, workspace read/list/search, git status/diff, the workspace export', () => {
  // 專案（L0 讀的是專案的 commit）：任何一段對上＝拒；列目錄、搜尋在翻頁之前就拿掉；git grep 先不碰。
  const projectRead = between(rooms, 'func projectRead(', 'func workspaceGitRun(');
  assert.match(projectRead, /if HandsSecretFiles\.isSecret\(components: parts\) \{ throw HandsToolError\.invalid\(HandsSecretFiles\.refusal\) \}/);
  assert.match(projectRead, /guard !HandsSecretFiles\.isSecret\(path: String\(fields\[1\]\)\) else \{ continue \}/);
  assert.match(projectRead, /args \+= HandsSecretFiles\.gitExcludePathspecs/);
  assert.match(projectRead, /\.filter \{ !HandsSecretFiles\.isSecret\(path: \$0\["path"\] as\? String \?\? ""\) \}/);
  // 工作區（L2）：讀、列、搜尋先過 preflightRead；git 狀態與差異連名字都不給。
  assert.match(between(rooms, 'func preflightRead(', 'func preflightPatch('), /if HandsSecretFiles\.isSecret\(components: parts\) \{ throw HandsToolError\.invalid\(HandsSecretFiles\.refusal\) \}/);
  assert.match(between(rooms, 'func gitStatus(', 'func gitDiff('), /\["path", "from"\]\.contains \{ HandsSecretFiles\.isSecret\(path: entry\[\$0\] as\? String \?\? ""\) \}/);
  assert.match(between(rooms, 'func gitDiff(', '// MARK: - L2 開工作區'), /spec = \(spec\.isEmpty \? \["--", "\."\] : spec\) \+ HandsSecretFiles\.gitExcludePathspecs/);
  // 開工作區的匯出：解開之後、建基準 commit 之前就刪掉（工作區裡根本沒有，run_command 也讀不到）。
  const exportScript = between(rooms, 'git --git-dir="$shadow"', 'git rev-parse HEAD');
  assert.ok(exportScript.indexOf('HandsSecretFiles.findExpression') > 0 && exportScript.indexOf('HandsSecretFiles.findExpression') < exportScript.indexOf('git -c init.defaultBranch'));
  // 檔案小幫手（第二道，沙盒裡跑）：讀、列、搜尋都擋。
  assert.match(fsopSource, /if \(isSecretPath\(parts\)\) fail\('secret_file_refused'\)/);
  assert.match(fsopSource, /names = names\.filter\(name => !isSecretName\(name\)\);/);
  assert.match(fsopSource, /if \(isSecretName\(name\)\) continue;/);
  // 自測（真的沙盒、真的 git）兩條。
  for (const label of ['W183 R10 底線 A：金鑰類檔案讀不到', 'W183 R10 底線 A：工作區裡的金鑰類檔案']) assert.ok(handsAcceptance.includes(label), label);
});

const scratch = () => fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183-r10-')));
const fsop = (request) => {
  const result = spawnSync(process.execPath, [fsopPath], { input: JSON.stringify(request), encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
};
// 金鑰類（會被擋的）與對照組（名字像、但不是；照樣讀得到）。
const SECRET_FILES = ['.env', '.env.production', '.envrc', 'config/credentials.json', 'keys/Server.PEM', 'deploy/id_ed25519', 'deploy/id_ed25519.pub',
  '.ssh/config', 'nested/.aws/credentials', 'backup/login.keychain-db', 'vault.KDBX', '.netrc', 'certs/site.crt', 'nested/.GnuPG/pubring.kbx',
  // W183 R10 第二輪（GPT-6 5；主導裁決）：錢包、secret*／secrets／.secrets、api key、service account、助記詞、seed*、Terraform 變數。
  'wallet.dat', 'coins/cold.Wallet', 'secrets.json', 'config/secret_key.txt', '.secrets/token', 'apikey.txt', 'API_KEY', 'keys/api-key.json',
  'gcp/service-account.json', 'notes/mnemonic.txt', 'Seed-Phrase.txt', 'infra/prod.tfvars'];
const CONTROL_FILES = ['src/app.js', 'README.md', 'docs/keyboard.md', 'src/monkey.js', 'notes/turkey', 'id.txt', 'environment.md', 'src/env.js',
  // 第二輪的對照組：名字像、但不是（照樣讀得到）。
  'src/wallet.ts', 'docs/my-secrets.md', 'src/deseed.js', 'infra/main.tf', 'docs/api.md'];
const plant = (root) => {
  for (const [i, rel] of [...SECRET_FILES, ...CONTROL_FILES].entries()) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), `TOKEN_${i}=r10canary\n`);
  }
};

test('(c) the file helper refuses every key file (read, list, search, any case, any depth) and still serves the look-alikes', () => {
  const root = scratch();
  plant(root);
  for (const rel of SECRET_FILES) {
    // 守：讀＝secret_file_refused（不說是哪一種、不回內容）。
    const reply = fsop({ op: 'read', root, path: rel });
    assert.equal(reply.error, 'secret_file_refused', rel);
    assert.doesNotMatch(JSON.stringify(reply), /r10canary/, rel);
  }
  for (const rel of CONTROL_FILES) assert.match(fsop({ op: 'read', root, path: rel }).lines, /r10canary/, rel);
  // 守：列目錄不列（翻頁之前就拿掉）；金鑰類資料夾本身也不給列。
  const listed = (dir) => fsop({ op: 'list', root, path: dir }).items.map((item) => item.path);
  assert.deepEqual(listed('').filter((p) => /^\.env|^\.ssh|^\.netrc|vault/i.test(p)), []);
  // 第二輪：最上層的金鑰類（檔案與 .secrets 資料夾）也不列。
  const top = listed('');
  for (const rel of [...SECRET_FILES.filter((x) => !x.includes('/')), '.secrets', '.ssh']) assert.ok(!top.includes(rel), rel);
  assert.deepEqual(listed('deploy'), []);
  assert.ok(listed('src').includes('src/monkey.js') && listed('docs').includes('docs/keyboard.md'));
  assert.equal(fsop({ op: 'list', root, path: '.ssh' }).error, 'secret_file_refused');
  assert.equal(fsop({ op: 'list', root, path: 'nested/.aws' }).error, 'secret_file_refused');
  // 守：搜尋不搜（內容裡的字找不到它們）；指定路徑到它們也不行。
  const found = fsop({ op: 'search', root, path: '', query: 'r10canary' }).items.map((item) => item.path);
  assert.deepEqual(found.filter((p) => SECRET_FILES.includes(p)), [], found.join(','));
  assert.deepEqual([...new Set(found)].sort(), [...CONTROL_FILES].sort());
  assert.equal(fsop({ op: 'search', root, path: 'nested/.aws', query: 'r10canary' }).error, 'secret_file_refused');
});

// App 用的 git 排除 pathspec、匯出用的 find 條件：照 HandsFloors.swift 的寫法產生（寫法本身下面核對），拿真的 git／find 跑。
const pathspecs = () => {
  const out = [];
  for (const name of [...SECRET.names, ...SECRET.directories]) out.push(`:(exclude,glob,icase)**/${name}`, `:(exclude,glob,icase)**/${name}/**`);
  for (const prefix of SECRET.prefixes) out.push(`:(exclude,glob,icase)**/${prefix}*`, `:(exclude,glob,icase)**/${prefix}*/**`);
  for (const suffix of SECRET.suffixes) out.push(`:(exclude,glob,icase)**/*${suffix}`, `:(exclude,glob,icase)**/*${suffix}/**`);
  return out;
};
const findExpression = () => {
  const tests = [];
  for (const name of [...SECRET.names, ...SECRET.directories]) tests.push(`-iname '${name}'`);
  for (const prefix of SECRET.prefixes) tests.push(`-iname '${prefix}*'`);
  for (const suffix of SECRET.suffixes) tests.push(`-iname '*${suffix}'`);
  return '\\( ' + tests.join(' -o ') + ' \\)';
};

test('(c) the git pathspecs and the export find expression really exclude key files (real git, real find; same construction as HandsFloors.swift)', () => {
  // 守：JS 這一份跟 Swift 的寫法一樣（改 Swift 的寫法要一起改這裡）。
  assert.ok(floors.includes('for name in names + directories { out.append(":(exclude,glob,icase)**/\\(name)"); out.append(":(exclude,glob,icase)**/\\(name)/**") }'));
  assert.ok(floors.includes('for prefix in prefixes { out.append(":(exclude,glob,icase)**/\\(prefix)*"); out.append(":(exclude,glob,icase)**/\\(prefix)*/**") }'));
  assert.ok(floors.includes('for suffix in suffixes { out.append(":(exclude,glob,icase)**/*\\(suffix)"); out.append(":(exclude,glob,icase)**/*\\(suffix)/**") }'));
  assert.ok(floors.includes(`for name in names + directories { tests.append("-iname '\\(name)'") }`));
  assert.ok(floors.includes(`for prefix in prefixes { tests.append("-iname '\\(prefix)*'") }`));
  assert.ok(floors.includes(`for suffix in suffixes { tests.append("-iname '*\\(suffix)'") }`));
  assert.ok(floors.includes('return "\\\\( " + tests.joined(separator: " -o ") + " \\\\)"'));
  // 真的 git：搜尋（git grep 專案的 commit）、差異（git diff）都看不到金鑰類；對照組照樣看得到；不是 128（pathspec 寫法 git 認得）。
  const root = scratch();
  const git = (args) => spawnSync('git', ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', ...args], { cwd: root, encoding: 'utf8' });
  assert.equal(git(['init', '-q', '.']).status, 0);
  plant(root);
  assert.equal(git(['add', '-A', '.']).status, 0);
  assert.equal(git(['-c', 'user.name=Fixture', '-c', 'user.email=r10-fixture', '-c', 'commit.gpgSign=false', 'commit', '-q', '-m', 'x']).status, 0);
  const grep = git(['grep', '-n', '-I', '--no-color', '--full-name', '-z', '-F', '-e', 'r10canary', 'HEAD', '--', ...pathspecs()]);
  assert.equal(grep.status, 0, grep.stderr);
  const grepped = [...new Set(grep.stdout.split('\n').filter(Boolean).map((line) => line.split('\0')[0].replace(/^HEAD:/, '')))].sort();
  assert.deepEqual(grepped, [...CONTROL_FILES].sort());
  // 指定 *.pem（使用者給的 glob）也一樣排除。
  const pem = git(['grep', '-n', '-F', '-e', 'r10canary', 'HEAD', '--', ':(glob)**/*.PEM', ...pathspecs()]);
  assert.equal(pem.status, 1, pem.stdout + pem.stderr);
  for (const rel of [...SECRET_FILES, ...CONTROL_FILES]) fs.appendFileSync(path.join(root, rel), 'changed\n');
  const diff = git(['diff', '--name-status', '-z', '--no-ext-diff', '--no-textconv', 'HEAD', '--', '.', ...pathspecs()]);
  assert.equal(diff.status, 0, diff.stderr);
  const changed = diff.stdout.split('\0').filter((x, i) => i % 2 === 1).sort();
  assert.deepEqual(changed, [...CONTROL_FILES].sort());
  // 真的 find：匯出之後刪掉金鑰類（整個資料夾也刪）；對照組留著。
  const ws = scratch();
  plant(ws);
  const find = spawnSync('/bin/sh', ['-c', `/usr/bin/find "$1" -mindepth 1 ${findExpression()} -prune -exec /bin/rm -rf -- {} +`, 'sh', ws], { encoding: 'utf8' });
  assert.equal(find.status, 0, find.stderr);
  for (const rel of SECRET_FILES) assert.ok(!fs.existsSync(path.join(ws, rel)), rel);
  for (const rel of CONTROL_FILES) assert.ok(fs.existsSync(path.join(ws, rel)), rel);
  assert.ok(!fs.existsSync(path.join(ws, '.ssh')) && !fs.existsSync(path.join(ws, 'nested/.aws')), 'key folders go as a whole');
});

// ---------- W183 R10 第二輪：底線 A 的清單與覆蓋面、底線 B 的別名與版本（GPT-6 4–8；主導裁決） ----------

test('(c) round 2: the list also has wallets, secret*/secrets/.secrets, api keys, service accounts, mnemonic/seed, *.tfvars — in both copies', () => {
  // 守：主導裁決點名的每一條都在 Swift 那一份（fsop.mjs 那一份由上面的 deepEqual 比對一樣）。
  assert.ok(SECRET.names.includes('wallet.dat'));
  for (const p of ['secret', 'secrets', '.secrets', 'apikey', 'api_key', 'api-key', 'service-account', 'mnemonic', 'seed']) assert.ok(SECRET.prefixes.includes(p), p);
  for (const x of ['.wallet', '.tfvars']) assert.ok(SECRET.suffixes.includes(x), x);
  // 舊工作區要照新規則再整理一次：清單或整理方式改了，版本跟著加（HandsSecretFiles.scanVersion；第三輪＝3：依賴的 .git、舊的
  // .build/repositories 整包隔離、工作區自己的 .git 封存後重建）。
  assert.match(floors, /static let scanVersion = 3/);
});

// Swift 的 Seatbelt 規則（HandsSecretFiles.seatbeltPattern）照同一個寫法在 JS 產生（寫法下面核對），拿真的 sandbox-exec 跑。
const ciPattern = (literal) => [...literal].map((ch) => {
  if (/[A-Za-z]/.test(ch)) return `[${ch.toLowerCase()}${ch.toUpperCase()}]`;
  if (ch === '.') return '[.]';
  if (/[\/\-_0-9]/.test(ch)) return ch;
  return ch.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
}).join('');
const seatbeltAlternatives = () => [
  ...[...SECRET.names, ...SECRET.directories].map(ciPattern),
  ...SECRET.prefixes.map((x) => ciPattern(x) + '[^/]*'),
  ...SECRET.suffixes.map((x) => '[^/]*' + ciPattern(x)),
];
const seatbeltWrap = (alternatives) => '/(' + alternatives.join('|') + ')(/|$)';
// 分段：跟 HandsSecretFiles.seatbeltPatterns 一樣的貪婪裝箱（每段不超過 900 字）。
const seatbeltPatterns = () => {
  const groups = [];
  for (const alternative of seatbeltAlternatives()) {
    const last = groups[groups.length - 1];
    if (last && Buffer.byteLength(seatbeltWrap([...last, alternative])) <= 900) last.push(alternative);
    else groups.push([alternative]);
  }
  return groups.map(seatbeltWrap);
};

test('(c) round 2: run_command and long jobs are denied by the sandbox rule itself (real sandbox-exec): no reading, no writing, no creating key files anywhere in the workspace; look-alikes and metadata still work', () => {
  // 守：JS 這一份跟 Swift 的寫法一樣（清單→每一項的樣子、包成一段、貪婪分段）。
  assert.ok(floors.includes('return (names + directories).map(ci) + prefixes.map { ci($0) + "[^/]*" } + suffixes.map { "[^/]*" + ci($0) }'));
  assert.ok(floors.includes('static func seatbeltWrap(_ alternatives: [String]) -> String { "/(" + alternatives.joined(separator: "|") + ")(/|$)" }'));
  assert.ok(floors.includes('if let last = groups.last, seatbeltWrap(last + [alternative]).utf8.count <= seatbeltChunkLimit {'));
  assert.match(floors, /static let seatbeltChunkLimit = 900/);
  // 守：Seatbelt 的一個字串最多約 1000 字（超過＝整份規則讀不進去、沙盒起不來、run_command 全壞）：整條早就超過，所以一定要分段。
  assert.ok(seatbeltWrap(seatbeltAlternatives()).length > 1024, 'the whole list no longer fits one Seatbelt string');
  for (const pattern of seatbeltPatterns()) assert.ok(Buffer.byteLength(pattern) <= 900, pattern.slice(0, 60));
  const sandbox = swift('Facade/HandsSandbox.swift');
  // 守：worker（run_command、長工作、檔案小幫手）讀寫都拒；唯讀（git 狀態、差異）拒讀內容；只作用在這個工作區裡；一段一條。
  const worker = between(sandbox, 'if paths.mode == .worker, paths.workspace != nil {', 'if paths.mode == .readOnly, paths.workspace != nil {');
  // 守（第三輪，GPT-6 5）：worker 能寫的每一處都照同一份清單拒讀拒寫——工作區與私有暫存（TMPDIR）各一條。
  assert.match(worker, /for pattern in HandsSecretFiles\.seatbeltPatterns \{\s*lines\.append\("\(deny file-read-data file-write\* \(require-all \(subpath \(param \\"WS\\"\)\) \(regex #\\"\\\(pattern\)\\"\)\)\)"\)\s*lines\.append\("\(deny file-read-data file-write\* \(require-all \(subpath \(param \\"SCRATCH\\"\)\) \(regex #\\"\\\(pattern\)\\"\)\)\)"\)\s*\}/);
  const readOnly = between(sandbox, 'if paths.mode == .readOnly, paths.workspace != nil {', 'var ownDirectory: String?');
  assert.match(readOnly, /for pattern in HandsSecretFiles\.seatbeltPatterns \{\s*lines\.append\("\(deny file-read-data \(require-all \(subpath \(param \\"WS\\"\)\) \(regex #\\"\\\(pattern\)\\"\)\)\)"\)\s*\}/);
  assert.doesNotMatch(sandbox, /regex #\\"\\\(HandsSecretFiles\.seatbeltPattern\)/, 'never the whole list as one Seatbelt string');
  // 工作區本身的路徑不能踩到這條規則（祖先是 .aws、secrets…＝整個工作區讀不到）：開工作區前就擋。
  assert.match(sandbox, /\[protectedPattern, protectedPathPattern, guardedDirectoryPattern, HandsSecretFiles\.seatbeltPattern\]\.contains/);
  // 真的沙盒：同一條規則（其他規則用 allow default 代替，只驗這一條的語法與比對）；工作區與暫存區各一條（跟 worker 一樣）。
  const ws = scratch();
  const tmp = scratch();
  plant(ws);
  const profile = '(version 1)(allow default)' + seatbeltPatterns().map((pattern) =>
    `(deny file-read-data file-write* (require-all (subpath "${ws}") (regex #"${pattern}")))`
    + `(deny file-read-data file-write* (require-all (subpath "${tmp}") (regex #"${pattern}")))`).join('');
  // 規則本身讀得進去（sandbox-exec 起得來、對照組照常）。
  const alive = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, '/usr/bin/true'], { encoding: 'utf8' });
  assert.equal(alive.status, 0, alive.stderr);
  const run = (command) => spawnSync('/usr/bin/sandbox-exec', ['-p', profile, '/bin/sh', '-c', command, 'sh'], { cwd: ws, encoding: 'utf8', timeout: 20_000 });
  for (const rel of SECRET_FILES) {
    const cat = run(`/bin/cat "${rel}"`);
    assert.notEqual(cat.status, 0, rel);
    assert.doesNotMatch(cat.stdout, /r10canary/, rel);
    // 覆寫、改名成別的名字（把內容帶出來）也不行。
    assert.notEqual(run(`echo x >> "${rel}"`).status, 0, `write ${rel}`);
    assert.notEqual(run(`/bin/mv "${rel}" "${rel}.moved-out"`).status, 0, `rename ${rel}`);
  }
  for (const rel of CONTROL_FILES) assert.match(run(`/bin/cat "${rel}"`).stdout, /r10canary/, rel);
  // 新建金鑰類（任何一層、大小寫都算）＝拒；對照組照樣建得出來；名字本身（metadata）看得到。
  for (const rel of ['fresh/.env', 'fresh/sub/.ENV.local', 'fresh/Secrets.txt', 'fresh/api_key', 'fresh/x/seed.bin', 'fresh/y/deploy.tfvars', 'fresh/.ssh/id_rsa']) {
    const made = run(`/bin/mkdir -p "$(dirname "${rel}")" && echo x > "${rel}"`);
    assert.ok(made.status !== 0 && !fs.existsSync(path.join(ws, rel)), rel);
  }
  assert.equal(run('echo x > src/new-file.js && /bin/cat src/new-file.js').stdout.trim(), 'x');
  // 繞路：硬連結（換個名字）建不出來；捷徑照真實路徑判（讀不到）；複製讀不到來源。
  assert.notEqual(run('/bin/ln .env src/hard-link.txt').status, 0);
  assert.doesNotMatch(run('/bin/ln -s ../.env src/soft-link.txt; /bin/cat src/soft-link.txt').stdout, /r10canary/);
  assert.notEqual(run('/bin/cp wallet.dat src/copied.txt').status, 0);
  assert.ok(!fs.existsSync(path.join(ws, 'src/copied.txt')) && !fs.existsSync(path.join(ws, 'src/hard-link.txt')));
  assert.equal(run('/bin/ls -d .env wallet.dat').status, 0, 'lstat (metadata) is not denied: git status keeps working');
  // 第三輪（GPT-6 5）的反例：金鑰類檔的中性上層資料夾整個搬到暫存區（TMPDIR）再讀＝一樣讀不到（規則照整條路徑比）；搬走本身可以。
  fs.mkdirSync(path.join(ws, 'planted'), { recursive: true });
  fs.writeFileSync(path.join(ws, 'planted/.env'), 'TOKEN=r10canary-planted\n');
  const moved = run(`/bin/mv planted "${tmp}/p" && echo mv-ok; /bin/cat "${tmp}/p/.env"; echo cat-$?`);
  assert.match(moved.stdout, /mv-ok/);
  assert.match(moved.stdout, /cat-[1-9]/);
  assert.doesNotMatch(moved.stdout, /r10canary/);
  // 暫存區裡也建不出金鑰類、也改不了名字；對照組照樣可以。
  assert.notEqual(run(`echo x > "${tmp}/secrets.txt"`).status, 0);
  assert.notEqual(run(`/bin/mv "${tmp}/p/.env" "${tmp}/p/plain.txt"`).status, 0);
  assert.equal(run(`echo x > "${tmp}/plain.txt" && /bin/cat "${tmp}/plain.txt"`).stdout.trim(), 'x');
  assert.notEqual(run('/bin/ls .ssh').status, 0, 'a key folder cannot be listed');
});

test('(c) round 2: every source that enters a workspace is filtered — dependencies too (their .git and key files go; .build/repositories never comes)', () => {
  // 守：可以帶進工作區的依賴不含 .build/repositories（沒清過的 Git 物件庫，git show 讀得到舊檔）。
  assert.match(rooms, /static let dependencyCandidates = \[".build\/checkouts", "node_modules"\]/);
  // 守：複製完先濾（濾不成＝整個不帶、刪掉複製出來的）。
  assert.match(rooms, /if copy\.exitCode == 0, sanitizeDependency\(target, workspace: workspace, scratch: scratch, admit: admit\) \{ copied\.append\(candidate\) \} else \{\s*missing\.append\(candidate\)\s*try\? FileManager\.default\.removeItem\(atPath: target\)/);
  const sanitize = between(rooms, 'func sanitizeDependency(', '/// read_file／list_dir／search');
  assert.match(sanitize, /guard result\.spawnError == nil, result\.exitCode == 0 else \{ return false \}\s*return Self\.secretEntries\(in: target\)\.isEmpty/);
  // 真的 zsh／find：照 Swift 的腳本（findExpression 換成同一個寫法的 JS 版）在一份假的 node_modules 上跑。
  const body = between(sanitize, 'let script = """', '"""\n        let result').replace('let script = """', '');
  const script = body.split('\n').map((line) => line.trim()).filter(Boolean).join('\n').replace('\\(HandsSecretFiles.findExpression)', findExpression());
  assert.match(script, /^setopt errexit\n\/usr\/bin\/find "\$1" -mindepth 1 -iname '\.git' -prune -exec \/bin\/rm -rf -- \{\} \+\n/);
  const deps = path.join(scratch(), 'node_modules');
  const files = {
    'dep/index.js': 'module.exports = 1;', 'dep/.git/HEAD': 'ref: refs/heads/main', 'dep/.git/objects/ab/cdef': 'blob', 'dep/.env': 'TOKEN=r10canary',
    'dep/config/secrets.json': '{"k":"r10canary"}', 'other/lib/wallet.dat': 'r10canary', 'other/lib/util.js': 'exports.u = 1;', 'other/package.json': '{}',
  };
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(deps, rel)), { recursive: true });
    fs.writeFileSync(path.join(deps, rel), text);
  }
  const ran = spawnSync('/bin/zsh', ['-f', '-c', script, 'tatwo-sanitize', deps], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(ran.status, 0, ran.stderr);
  for (const gone of ['dep/.git', 'dep/.env', 'dep/config/secrets.json', 'other/lib/wallet.dat']) assert.ok(!fs.existsSync(path.join(deps, gone)), gone);
  for (const kept of ['dep/index.js', 'other/lib/util.js', 'other/package.json']) assert.ok(fs.existsSync(path.join(deps, kept)), kept);
  // 自測（真的匯出、真的沙盒）。
  assert.ok(handsAcceptance.includes('W183 R10 第二輪 底線 A：依賴也濾'));
  assert.ok(handsAcceptance.includes('W183 R10 第二輪 底線 A：沙盒規則擋'));
});

test('(c) round 3: an old workspace is tidied before its first use — key files, other repositories\' .git and old .build/repositories are quarantined whole (moved, restore notes written first, never deleted); its own .git is archived and rebuilt clean (no reflog, no unreachable objects); every move is fd-relative and never follows a link; one tidy at a time', () => {
  const ensure = between(rooms, 'func ensureSecretScan(_ workspace: HandsWorkspace) throws -> HandsWorkspace {', 'private func migrate(');
  // 守：只在還沒照現在的規則整理過時做；同一個工作區一次一個（互斥，後到的看到版本已經是新的就直接用）；拿著寫入鎖（不准新的 worker）；
  // 還有工作在跑＝先不整理；失敗＝鎖住、不記版本、不自動重試。
  assert.match(ensure, /guard workspace\.record\.secretScan != HandsSecretFiles\.scanVersion else \{ return workspace \}/);
  assert.match(ensure, /return try HandsQuarantine\.withWorkspaceMutex\(workspace\.id\) \{/);
  assert.match(ensure, /if record\.secretScan == HandsSecretFiles\.scanVersion \{ return current \}/);
  assert.match(ensure, /if record\.lockReason == "secret_migration_failed" \{/);
  assert.match(ensure, /guard lockWorkspace\(workspace\.id\.uuidString\) else \{/);
  assert.match(ensure, /guard !HandsSandbox\.isRunning\(where: \{ \$0\.workspace == workspace\.id\.uuidString \}\) else \{/);
  // 第四輪：鎖的時候把「等重新整理」「暫停整理」兩種暫時的鎖換成準的原因（別的原因鎖著的不動）。
  assert.match(ensure, /\} catch \{\s*lockForSecrets\(workspace\.id, reason: "secret_migration_failed"\)/);
  assert.ok(ensure.indexOf('try migrate(current)') < ensure.indexOf('$0.secretScan = HandsSecretFiles.scanVersion'), 'the version is written only after it worked');
  const migrate = between(rooms, 'private func migrate(', 'private func rebuildGit(');
  // 守：找金鑰類與別人的 .git（nestedGit）；舊的 .build/repositories 整包（它底下找到的不另外搬）；根的 .git 封存後重建；最後照舊看歷史。
  assert.match(migrate, /scanned = try HandsQuarantine\.scan\(repoFD, nestedGit: true\)/);
  assert.match(migrate, /let repositories = "\.build\/repositories"/);
  assert.match(migrate, /items \+= scanned\.filter \{ !hasRepositories \|\| !\$0\.lowercased\(\)\.hasPrefix\(repositories \+ "\/"\) \}/);
  assert.match(migrate, /rootGit: rootGit, reason:/);
  assert.match(migrate, /if rootGit \{ try rebuildGit\(workspace, archive: folder \+ "\/git-archive"\) \}/);
  assert.match(migrate, /if historyHasSecret \{ lockForSecrets\(workspace\.id, reason: "secret_in_history"\) \}/);
  assert.doesNotMatch(code(migrate + ensure), /removeItem|unlink\(|rmdir\(/, 'nothing is deleted');
  // 守：重建在沙盒裡（只准寫 repo/.git、只讀封存）；只帶 ref 摸得到的物件（--no-local）、沒有 reflog；HEAD 要跟舊的一樣。
  const rebuild = between(rooms, 'private func rebuildGit(', 'func quarantineNewSecrets(');
  assert.match(rebuild, /sandboxPaths\(mode: \.commit, workspace: workspace, scratch: workspace\.scratch, readOnly: \[archive\], forHelper: true\)/);
  const script = rebuild.slice(rebuild.indexOf('let script = """') + 'let script = """'.length, rebuild.indexOf('"""\n        let result'));
  assert.match(script, /clone --mirror --no-local --no-hardlinks --template= -q "\$1" "\$2\/\.git"/);
  assert.match(script, /\[\[ "\$old" == "\$new" \]\]/);
  // 守：執行前隔離——run_command、job_start 在寫入鎖裡先把新出現的金鑰類檔與別人的 .git 搬去隔離；搬不成＝鎖住、不跑。
  const pre = between(rooms, 'func quarantineNewSecrets(', '/// 工作樹裡最上層的金鑰類項目');
  assert.match(pre, /try HandsQuarantine\.withWorkspaceMutex\(workspace\.id\) \{/);
  assert.match(pre, /found = try HandsQuarantine\.scan\(repoFD, nestedGit: true\)/);
  assert.match(pre, /lockForSecrets\(workspace\.id, reason: "secret_quarantine_failed"\)/);
  assert.match(tools, /try service\.quarantineNewSecrets\(workspace\)   \/\/ W183 R10 第三輪（GPT-6 5）/);
  // 守（GPT-6 8）：搬移從驗證過的資料夾 descriptor 逐層 openat(O_NOFOLLOW | O_DIRECTORY)，renameat（descriptor 相對），搬之前、之後核對身分；
  // 還原說明在搬任何東西之前先寫（O_EXCL | O_NOFOLLOW、寫完 fsync；寫不成＝整次失敗）。
  const quarantine = read('App/Sources/Tatwo2/Facade/HandsQuarantine.swift');
  assert.match(quarantine, /let next = openat\(fd, part, O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC\)/);
  assert.match(quarantine, /guard renameat\(source, name, target, targetName\) == 0 else \{ throw Failure\("rename_failed"\) \}/);
  assert.match(quarantine, /after\.st_dev == before\.st_dev, after\.st_ino == before\.st_ino else \{\s*throw Failure\("identity_changed"\)/);
  assert.match(quarantine, /let fd = openat\(dir, name, O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC, 0o600\)/);
  assert.match(quarantine, /guard ok, fsync\(fd\) == 0 else \{ throw Failure\("restore_note_write_failed"\) \}/);
  const body = between(quarantine, 'static func quarantine(workspaceID: UUID,', '\n    }\n}');
  assert.ok(body.indexOf('try writeNew(quarantineFD, "RESTORE.txt"') < body.indexOf('for item in items { try move('), 'restore notes first');
  assert.doesNotMatch(code(quarantine), /removeItem|unlink\(|rmdir\(/, 'nothing deleted');
  // 搬移、掃描、一次隔離都只用 descriptor（第四輪的指紋只列資料夾、不搬東西，不在這個範圍）。
  assert.doesNotMatch(code(between(quarantine, 'static func openDirectory(', 'static func gitFingerprint(')), /FileManager/, 'moves and scans use descriptors only');
  assert.doesNotMatch(code(between(quarantine, 'static func quarantine(workspaceID: UUID,', '\n    }\n}')), /FileManager/);
  // 真的 git：照 Swift 的重建腳本（同一段 zsh）把一個有「摸不到的 blob」「只在 reflog 的 commit」的倉庫重建：物件與 reflog 都不在、HEAD 一樣、
  // info/exclude 帶回來；封存（舊的 .git）裡都還在。
  const root = scratch();
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo);
  const git = (args, cwd = repo) => spawnSync('git', ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
    '-c', 'user.email=r10-fixture', '-c', 'commit.gpgSign=false', ...args], { cwd, encoding: 'utf8' });
  assert.equal(git(['init', '-q', '.']).status, 0);
  fs.writeFileSync(path.join(repo, 'app.js'), 'x\n');
  assert.equal(git(['add', '-A']).status, 0);
  assert.equal(git(['commit', '-q', '-m', 'base']).status, 0);
  const head = git(['rev-parse', 'HEAD']).stdout.trim();
  fs.writeFileSync(path.join(root, 'blob.txt'), 'r10canary-dangling\n');
  const dangling = git(['hash-object', '-w', path.join(root, 'blob.txt')]).stdout.trim();
  fs.writeFileSync(path.join(repo, 'leak.txt'), 'r10canary-reflog\n');
  assert.equal(git(['add', 'leak.txt']).status, 0);
  assert.equal(git(['commit', '-q', '-m', 'leak']).status, 0);
  const leak = git(['rev-parse', 'HEAD']).stdout.trim();
  assert.equal(git(['reset', '-q', '--hard', 'HEAD~1']).status, 0);
  fs.mkdirSync(path.join(repo, '.git/info'), { recursive: true });
  fs.writeFileSync(path.join(repo, '.git/info/exclude'), 'node_modules\n');
  assert.equal(git(['cat-file', '-e', dangling]).status, 0, 'fixture: dangling blob present');
  assert.equal(git(['cat-file', '-e', leak]).status, 0, 'fixture: reflog-only commit present');
  const archive = path.join(root, 'git-archive');
  fs.renameSync(path.join(repo, '.git'), archive);   // Swift 用 renameat 搬（HandsQuarantine.move）
  const lines = script.split('\n').map((line) => line.trim()).filter(Boolean).join('\n');
  const ran = spawnSync('/bin/zsh', ['-f', '-c', lines, 'tatwo-rebuild-git', archive, repo, 'git'], { encoding: 'utf8', timeout: 60_000 });
  assert.equal(ran.status, 0, ran.stderr);
  assert.equal(ran.stdout.trim(), head);
  assert.equal(git(['rev-parse', 'HEAD']).stdout.trim(), head);
  assert.notEqual(git(['cat-file', '-e', dangling]).status, 0, 'unreachable blob is gone from the rebuilt repository');
  assert.notEqual(git(['cat-file', '-e', leak]).status, 0, 'reflog-only commit is gone');
  assert.equal(git(['reflog']).stdout.trim(), '');
  assert.equal(fs.readFileSync(path.join(repo, '.git/info/exclude'), 'utf8'), 'node_modules\n');
  assert.equal(git(['config', '--get', 'core.bare']).stdout.trim(), 'false');
  assert.notEqual(git(['config', '--get', 'remote.origin.url']).status, 0, 'no remote pointing at the archive');
  assert.equal(git(['status', '--porcelain']).stdout.trim(), '', 'index rebuilt from HEAD; the working tree is untouched');
  assert.equal(git(['--git-dir=' + archive, 'cat-file', '-e', dangling], root).status, 0, 'the archive keeps everything (restore = move it back)');
  // 真的 git：歷史的判斷照舊（-z 分段、同一張清單）。
  const history = git(['log', '--all', '--no-renames', '--name-only', '--format=', '-z']);
  assert.equal(history.status, 0);
  for (const label of ['W183 R10 第三輪 舊工作區整理', 'W183 R10 第三輪 執行前隔離', 'W183 R10 第三輪 雙掃描＋中間資料夾換成捷徑',
    'W183 R10 第三輪 雙掃描（沒有捷徑）', 'W183 R10 第三輪 暫存區也擋']) {
    assert.ok(handsAcceptance.includes(label), label);
  }
});

test('(c) round 4: after a restore (RESTORE.txt) the workspace is locked and re-tidied before any use — a re-appeared .build/repositories or a replaced root .git (fingerprint) invalidates the tidy; the tidy pauses (lock + one sentence) instead of rebuilding over staged, partly staged or conflicted work; restore notes tell the truth', () => {
  // 守（GPT-6 發現 2）：任何一次用到（workspace()，讀的工具也算）與執行前都看：.build/repositories 又出現、根 .git 的指紋對不上（沒記過也算）
  // ＝先鎖住（secret_recheck_needed）、整理認證失效；workspace() 當場重新整理，執行前（拿著寫入鎖）＝這一次不跑。
  assert.match(rooms, /static func needsRecheck\(repo: String, record: HandsWorkspaceRecord\) -> Bool \{\s*var info = stat\(\)\s*if lstat\(repo \+ "\/\.build\/repositories", &info\) == 0 \{ return true \}\s*guard let known = record\.gitFingerprint else \{ return true \}\s*return HandsQuarantine\.gitFingerprint\(repo: repo\) != known/);
  const open = between(rooms, 'func workspace(_ raw: String, grant: HandsGrantAccess, settings: HandsSettings, forWrite: Bool = false)', 'func ensureSecretScan(');
  assert.match(open, /if current\.secretScan == HandsSecretFiles\.scanVersion, Self\.needsRecheck\(repo: realRepo, record: current\) \{\s*invalidateSecretScan\(id\)/);
  assert.ok(open.indexOf('invalidateSecretScan(id)') < open.indexOf('try ensureSecretScan('), 'invalidated before the tidy runs');
  const pre = between(rooms, 'func quarantineNewSecrets(', '/// 工作樹裡最上層的金鑰類項目');
  assert.match(pre, /if let record = workspaceStore\.record\(workspace\.id\), Self\.needsRecheck\(repo: workspace\.repo, record: record\) \{\s*invalidateSecretScan\(workspace\.id\)\s*throw HandsToolError\.invalid\("workspace_rechecking: /);
  assert.match(rooms, /func invalidateSecretScan\(_ id: UUID\) \{\s*if workspaceStore\.record\(id\)\?\.isLocked == false \{\s*workspaceStore\.lock\(where: \{ \$0\.id == id \}, reason: "secret_recheck_needed"\)\s*\}\s*_ = try\? workspaceStore\.update\(id\) \{ \$0\.secretScan = nil \}/);
  // 守：整理好才解開（只解「等重新整理」「暫停整理」這兩種；歷史裡有金鑰類＝上面換成 secret_in_history，不解）；記下新的指紋。
  const ensure = between(rooms, 'func ensureSecretScan(_ workspace: HandsWorkspace) throws -> HandsWorkspace {', 'static let migrationPausedReason');
  assert.match(ensure, /\$0\.gitFingerprint = fingerprint\s*\/\/[^\n]*\n\s*if \$0\.lockReason == "secret_recheck_needed" \|\| \$0\.lockReason == Self\.migrationPausedReason \{\s*\$0\.status = "open"\s*\$0\.lockReason = nil/);
  // 守：App 自己寫 .git 的地方都記新的指紋（建好、交件的 commit），而且不讓 git 自己在背景整理物件（gc.auto=0）。
  assert.match(rooms, /record\.gitFingerprint = HandsQuarantine\.gitFingerprint\(repo: repo\)/);
  assert.match(rooms, /let committedFingerprint = HandsQuarantine\.gitFingerprint\(repo: workspace\.repo\)\s*_ = try\? workspaceStore\.update\(workspace\.id\) \{ \$0\.gitFingerprint = committedFingerprint \}/);
  assert.equal((rooms.match(/-c gc\.auto=0/g) || []).length, 2, 'export baseline and submit commit');
  const quarantine = read('App/Sources/Tatwo2/Facade/HandsQuarantine.swift');
  assert.match(quarantine, /static func gitFingerprint\(repo: String\) -> String\? \{/);
  assert.match(quarantine, /return "\\\(gitInfo\.st_dev\):\\\(gitInfo\.st_ino\)\|\\\(objectsInfo\.st_dev\):\\\(objectsInfo\.st_ino\)\|alt=\\\(alternates\)\|/);
  // 守：還原說明照實寫——先把目前的 .git 封存（不蓋掉整理之後的新工作）；還原之後會重新整理（不宣稱還原之後仍讀不到）。
  assert.match(quarantine, /先把目前的 repo\/\.git 搬進這個資料夾（例如改名成 git-current）——那是整理之後的新工作，不要直接蓋掉。/);
  assert.match(quarantine, /會發現、先鎖住、重新整理一次/);
  assert.doesNotMatch(quarantine, /照樣讀不到/);
  // 守（GPT-6 發現 4；二選一＝暫停）：整理前看只存在 index 的工作與進行中的 Git 操作；有＝鎖住（secret_migration_paused）、一句話說明、
  // 什麼都不搬；處理完下一次照常整理。
  assert.ok(ensure.indexOf('if let pending = try pendingGitWork(current)') < ensure.indexOf('try migrate(current)'), 'checked before anything moves');
  assert.match(ensure, /lockForSecrets\(workspace\.id, reason: Self\.migrationPausedReason\)\s*throw HandsToolError\.invalid\("workspace_locked: \\\(Self\.migrationPausedReason\) — this workspace has \\\(pending\);/);
  const pending = between(rooms, 'private func pendingGitWork(', '/// 整理一個舊工作區');
  for (const name of ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer']) assert.ok(pending.includes(`"${name}"`), name);
  assert.match(pending, /workspaceGitRun\(workspace, \["ls-files", "-u", "-z"\]\)/);
  assert.match(pending, /workspaceGitRun\(workspace, \["diff", "--cached", "--quiet", "--no-ext-diff", "--ignore-submodules=none"\]\)/);
  assert.match(pending, /if staged\.exitCode == 1 \{ return "staged changes that are not committed" \}/);
  // 真的 git：同一組指令認得出三種狀態（只有暫存、部分暫存、衝突），乾淨的不算。
  const root = scratch();
  const git = (args, cwd = root) => spawnSync('git', ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
    '-c', 'user.email=r10-fixture', '-c', 'commit.gpgSign=false', ...args], { cwd, encoding: 'utf8' });
  const staged = () => git(['diff', '--cached', '--quiet', '--no-ext-diff', '--ignore-submodules=none']).status;
  const unmerged = () => git(['ls-files', '-u', '-z']).stdout;
  assert.equal(git(['init', '-q', '-b', 'main', '.']).status, 0);
  fs.writeFileSync(path.join(root, 'README.md'), 'A\n');
  assert.equal(git(['add', '-A']).status, 0);
  assert.equal(git(['commit', '-q', '-m', 'a']).status, 0);
  assert.equal(staged(), 0, 'clean');
  fs.writeFileSync(path.join(root, 'README.md'), 'B\n');
  git(['add', 'README.md']);
  fs.writeFileSync(path.join(root, 'README.md'), 'A\n');   // 工作樹改回 HEAD 的版本（checkout -- 會從 index 拿，不能用）
  assert.equal(staged(), 1, 'staged-only: B only lives in the index');
  assert.equal(fs.readFileSync(path.join(root, 'README.md'), 'utf8'), 'A\n');
  fs.writeFileSync(path.join(root, 'README.md'), 'B\nC\n');
  assert.equal(staged(), 1, 'partly staged');
  git(['reset', '-q', '--hard']);
  git(['checkout', '-q', '-b', 'side']);
  fs.writeFileSync(path.join(root, 'README.md'), 'side\n');
  git(['commit', '-q', '-am', 'side']);
  git(['checkout', '-q', 'main']);
  fs.writeFileSync(path.join(root, 'README.md'), 'main\n');
  git(['commit', '-q', '-am', 'main']);
  assert.notEqual(git(['merge', '-q', 'side']).status, 0);
  assert.ok(unmerged().length > 0 && fs.existsSync(path.join(root, '.git/MERGE_HEAD')), 'conflict: unmerged entries and MERGE_HEAD');
  for (const label of ['W183 R10 第四輪 遷移成功→照 RESTORE.txt 還原→再跑', 'W183 R10 第四輪 使用者的 Git 工作不被重建洗掉',
    'W183 R10 第四輪 清單修訂與交件同一個序列']) {
    assert.ok(handsAcceptance.includes(label), label);
  }
});

test('(c) round 2: a project whose root folder itself is a key folder (.aws, credentials-backup…) is out of scope entirely', () => {
  assert.match(floors, /static func isSecretRoot\(_ path: String, home: String\) -> Bool \{/);
  // 家目錄以下那一段才算（使用者名稱不算）；設定的路徑、真實路徑任一個是＝拿掉。
  assert.match(floors, /let tail = standard\.lowercased\(\)\.hasPrefix\(base\.lowercased\(\) \+ "\/"\) \? String\(standard\.dropFirst\(base\.count \+ 1\)\) : standard/);
  assert.match(scope, /!HandsSecretFiles\.isSecretRoot\(workdir, home: home\)\s*&& !\(HandsPath\.realpath\(workdir\)\.map \{ HandsSecretFiles\.isSecretRoot\(\$0, home: home\) \} \?\? false\)/);
  // 所有讀專案清單的路（工具、範圍快照、面板）都走 allProjectRecords：兩個來源（自測的替身、真的 Coder 清單）都先拿掉。
  const all = between(scope, 'func allProjectRecords() -> [(UUID, String, String)] {', 'static func withoutSecretRoots(');
  assert.equal((all.match(/Self\.withoutSecretRoots\(/g) || []).length, 2);
  assert.ok(handsAcceptance.includes('W183 R10 第二輪 底線 A：專案根目錄本身是金鑰類資料夾（credentials-backup）＝整個專案不納入範圍'));
});

test('(b) round 2: trading projects are classified by the folder\'s real identity (realpath, device+inode, shared git repository) — any name that hits makes every alias L0; the classification is versioned, running work is cancelled on a change, submit re-checks the version', () => {
  const trading = between(floors, 'enum HandsTradingFloor {', '\n}\n');
  // 守：別名彙整——任一個命中，共用任一個身分（真實路徑、裝置＋inode、Git 儲存庫本體）的專案全部都是。
  assert.match(trading, /for \(id, keys\) in keysByID where !keys\.isDisjoint\(with: tradingKeys\) \{ out\.insert\(id\.uuidString\) \}/);
  assert.match(trading, /var keys: Set<String> = \["path:" \+ real\.lowercased\(\)\]/);
  assert.match(trading, /if stat\(real, &info\) == 0 \{ keys\.insert\("ino:\\\(info\.st_dev\):\\\(info\.st_ino\)"\) \}/);
  assert.match(trading, /if let common = gitCommonDir\(real\) \{ keys\.insert\("git:" \+ common\.lowercased\(\)\) \}/);
  // 守：worktree 的 .git 檔（gitdir: …）→ commondir 的真實路徑；只讀檔案、不跑 git。
  assert.match(trading, /let line = text\.split\(separator: "\\n"\)\.first, line\.hasPrefix\("gitdir:"\)/);
  assert.match(trading, /if let common = try\? String\(contentsOfFile: resolved \+ "\/commondir", encoding: \.utf8\) \{/);
  // 守：分類變了＝版本加一；新變成交易類的專案，它們工作區裡跑著的工作當下取消（長工作與 run_command 的行程）。
  // 第三輪（GPT-6 6）：每一次讀清單都有序號；只有比已經發布的新（序號大）才發布——晚到的舊計算丟掉；發布跟交件的 update-ref 同一把鎖。
  const note = between(service, 'func noteProjectRecords(_ records: [(UUID, String, String)], seq: UInt64, digest: String) {', 'var tradingVersion: UInt64 {');
  assert.match(note, /let trading = HandsTradingFloor\.classify\(records\)/);
  assert.ok(note.indexOf('HandsTradingFloor.classify(records)') < note.indexOf('publicationLock.lock()'), 'the file work happens outside the locks');
  assert.match(note, /publicationLock\.lock\(\)\s*floorLock\.lock\(\)\s*guard seq > publishedSeq else \{\s*floorLock\.unlock\(\)\s*publicationLock\.unlock\(\)\s*return\s*\}/);
  assert.match(note, /publishedSeq = seq\s*publishedListDigest = digest/);
  assert.match(note, /if trading != tradingProjectIDs \{\s*tradingProjectIDs = trading\s*tradingVersionValue &\+= 1\s*\}/);
  assert.match(note, /floorLock\.unlock\(\)\s*publicationLock\.unlock\(\)\s*if !newly\.isEmpty \{ cancelWork\(forProjects: newly\) \}/);
  // 守：待分類＝最新讀到的那一份跟已經發布的不一樣；專案的寫入與執行在工具入口與最後一道（admission：啟動、發布）都先拒。
  assert.match(service, /var classificationPending: Bool \{\s*floorLock\.lock\(\); defer \{ floorLock\.unlock\(\) \}\s*return latestListDigest != publishedListDigest\s*\}/);
  assert.match(service, /if level > HandsTradingFloor\.maxLevel, classificationPending \{ return "classification_pending" \}/);
  assert.match(tools, /if arguments\["project_id"\] != nil \|\| arguments\["workspace_id"\] != nil, service\.classificationPending \{\s*return pendingRefusal\s*\}/);
  // 守：讀清單的那一刻發序號（主執行緒；自測替身也排成一條），分類照那個序號發布。
  const all = between(scope, 'func allProjectRecords() -> [(UUID, String, String)] {', 'static func withoutSecretRoots(');
  assert.match(all, /return \(list, self\.noteListRead\(Self\.projectListDigest\(list\)\)\)/);
  assert.match(all, /if seq > 0 \{ noteProjectRecords\(records, seq: seq, digest: Self\.projectListDigest\(raw\)\) \}/);
  assert.match(all, /let \(raw, seq\) = readOverride\(projectsOverride\)/);
  const cancel = between(service, 'private func cancelWork(forProjects ids: Set<String>) {', 'static func tradingRecord(');
  assert.match(cancel, /jobs\.cancel\(where: \{ affected\.contains\(\$0\.workspaceID\) \}, marksDirectory: marks\)/);
  assert.match(cancel, /HandsSandbox\.terminate\(where:/);
  // 守：Coder 的專案清單一變（改名、新增、換資料夾；引擎把文件交給畫面的那一刻）就在背景重算分類，不等有人讀清單。
  const attach = between(service, '@MainActor func attach(model: ChatPageModel) {', 'static func attached(to model: ChatPageModel) -> HandsService {');
  assert.match(attach, /projectWatch = model\.\$document\.sink \{ \[weak self\] _ in\s*MainActor\.assumeIsolated \{ self\?\.projectListMayHaveChanged\(\) \}/);
  assert.match(attach, /let digest = Self\.projectListDigest\(list\)/);
  // 第三輪：變了的那一刻就記成最新的一份（待分類：受影響的寫入先拒），背景算完、比已經發布的新才發布。
  assert.match(attach, /guard digest != lastProjectDigest else \{ return \}\s*lastProjectDigest = digest\s*\/\/[^\n]*\n\s*noteListRead\(digest\)\s*DispatchQueue\.global\(qos: \.utility\)\.async \{ \[weak self\] in self\?\.refreshTradingClassification\(\) \}/);
  assert.ok(handsAcceptance.includes('W183 R10 第二輪 底線 B：Coder 裡新增交易類專案（沒有工作在跑、沒叫列表）＝手腳當下重算分類、版本加一'));
  // 守：不靠有人叫列表——長工作的監看每一輪都重讀分類（改名後下一輪就停）；工具入口也是即時重讀。
  assert.match(swift('Facade/HandsJobs.swift'), /service\.refreshTradingClassification\(\)/);
  assert.match(between(service, 'func isTradingProject(_ projectID: UUID) -> Bool {', '}\n'), /refreshTradingClassification\(\)/);
  // 守：交件前重讀、記下版本；發布那一刻（鎖裡）版本變了或這個專案成了交易類＝不交件（鎖裡的 admission 另外看待分類）。
  const submit = between(rooms, 'let classification = refreshTradingClassification()', '_ = try HandsGit.checked(["update-ref"');
  // 第四輪（GPT-6 發現 3）：鎖裡最後一次檢查（待分類、版本、交易類）＋update-ref 在提交序列裡——清單修訂插不進中間。
  assert.match(submit, /try withCommitSequence \{\s*guard !classificationPending, tradingVersion == classification, !isTradingCached\(project\.id\) else \{\s*throw HandsToolError\.invalid\("classification_changed: /);
  assert.match(submit, /submitFinalGate\?\(\)/);
  assert.match(service, /func noteListRead\(_ digest: String\) -> UInt64 \{\s*\/\/[^\n]*\n\s*commitSequence\.lock\(\); defer \{ commitSequence\.unlock\(\) \}\s*floorLock\.lock\(\)/);
  assert.match(service, /func withCommitSequence<T>\(_ body: \(\) throws -> T\) rethrows -> T \{\s*commitSequence\.lock\(\); defer \{ commitSequence\.unlock\(\) \}/);
  assert.match(submit, /#if DEBUG\s*submitGate\?\(\)/);
  assert.ok(submit.indexOf('submitGate?()') < submit.indexOf('try withPublication('), 'the barrier sits between the check and the locked publication');
  // 守：列表標只能看、範圍快照的 readOnly 都看彙整過的那一份（不是只看自己的名字）。
  assert.match(rooms, /let trading = isTradingCached\(id\)/);
  assert.match(service, /let readOnly = records\.filter \{ isTradingCached\(\$0\.0\) \}\.map \{ \$0\.0\.uuidString \}\.sorted\(\)/);
  for (const label of ['W183 R10 第二輪 底線 B：別名——同一個資料夾（捷徑）另一個名字命中「BTC 實盤」', 'W183 R10 第二輪 底線 B：執行中改名成交易實盤類（沒叫列表）＝跑著的長工作在下一輪監看就被取消',
    'W183 R10 第三輪 分類的序號：舊清單的計算晚到（barrier 壓著）不蓋掉新的', 'W183 R10 第三輪 待分類：清單剛變、還沒算好＝寫入、執行、交件的最後一道檢查先拒',
    'W183 R10 第三輪 交件：分類檢查之後、發布之前改名成交易類（barrier）＝發布鎖裡看到、不交件']) {
    assert.ok(handsAcceptance.includes(label), label);
  }
});

test('(a) round 2: raising the central level L1 → L2 does not widen a grant that was made at L1 (real tool calls in the self-test)', () => {
  // 守：恢復「中央放大、舊 grant 不跟著變大」的實際工具授權測試（工具清單、叫 L2 的工具、一個工作區都沒開）。
  assert.match(scopeAcceptance, /try scopeOldGrant\(check, base\)/);
  const old = between(scopeAcceptance, '@MainActor static func scopeOldGrant(', '\n    }\n');
  assert.match(old, /service\.scopeCap = \{ \(level: 1, projects: \[\]\) \}/);
  assert.match(old, /service\.scopeCap = \{ \(level: 2, projects: \[\]\) \}/);
  assert.match(old, /service\.handle\(method: "hands_call"/);
  assert.match(old, /after\?\.level == 1 && tools\["level"\] as\? Int == 1\s*&& !names\.contains\("open_workspace"\) && !names\.contains\("run_command"\)/);
  assert.ok(scopeAcceptance.includes('W183 R10 第二輪 中央設定 L1 → L2：已經連上的 L1 grant 照舊只有 L1'));
  // 主機端：工具等級＝min(grant 的等級, 現在的中央等級)。
  assert.match(service, /let level = min\(grant\.grantLevel, current\.level\)/);
});

// ---------- (d) 連線卡沒有專案層 ----------

test('(d) the connect card has no project layer and no "go tick in ChatGPT build" hint; ［連線］ starts right away; the consent line sits next to it', () => {
  assert.doesNotMatch(dmView, /HandsConnectScopeChooser|HandsConnectLevelSegments|HandsConnectSheetPage|HandsConnectNavRow|toggleProject|chooseLevel|先到那裡勾|uncheckedNote/);
  assert.doesNotMatch(connect, /func chooseLevel\(|func toggleProject\(/);
  assert.match(connect, /static let consentLine = "按連線＝同意 ChatGPT 開發者模式的風險說明，TATWO 會替你勾選"/);
  assert.match(dmView, /Text\(HandsConnectFlow\.consentLine\)/);
  assert.match(dmView, /DMPhoneCapsuleButton\(title: "連線", prominent: true\) \{ actions\.connect\(\) \}\s*\.help\(HandsConnectFlow\.consentLine\)/);
  // 主機：帶了範圍的 begin 在任何副作用之前就拒（卡片、副設備都改不到範圍）。
  const begin = between(host, 'func begin(_ request: HandsConnectRequest', 'func cancel(attemptID');
  assert.ok(begin.indexOf('guard request.choice == nil else { throw HandsConnectRefusal.scopeInvalid }') >= 0
    && begin.indexOf('guard request.choice == nil else { throw HandsConnectRefusal.scopeInvalid }') < begin.indexOf('commitLock.lock()'));
  assert.doesNotMatch(code(host) + code(scope), /applyChoice|validatedChoice/);
  // 面板的［連線］不帶範圍；卡片只剩進度與結果（等級、專案、記憶一組只顯示）。
  assert.match(swift('Facade/HandsBuildController.swift'), /dependencies\.flow\.offer\(target: target, preset: nil\)/);
  assert.match(dmView, /\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.scopeSummary"\)/);
  for (const label of ['W183 R10 卡片：範圍＝這台全部專案', 'W183 R10 主機一律不收卡上選的範圍']) assert.ok(scopeAcceptance.includes(label), label);
});

// ---------- (e) 代勾只勾那一格 ----------

test('(e) auto-tick: only the one known box, by CEF\'s node-verified native (isTrusted) click on the same document, once; a consent text that is not a verified version, an unknown checkbox or a moved box goes to the user with one sentence', () => {
  // Pod 腳本只量位置（動態測試在 w183-connect）；App 只在 risk_ack＋位置合法時才當成可以代勾。
  // W183 R10 第二輪（GPT-6 3）：同意內容對不上核實過的版本（Pod 回 consent: unknown）＝不代勾，就算帶了位置也一樣（先判這個）。
  // W183 R12（主導 3）：不認得的同意內容另外帶那一份（offer）給卡片顯示全文；守的一樣：consent unknown＝說明改了、不代勾。
  assert.match(pod, /if step == "risk_ack", data\["consent"\] as\? String == "unknown" \{[\s\S]{0,400}?return \.needsUser\(HandsConnectFlow\.warningChangedReason, offered\)\s*\}/);
  assert.match(pod, /if step == "risk_ack", let ack, let target = HandsTickTarget\(wire: data\["tick"\], generation: generation\) \{ return \.tickable\(ack, target\) \}/);
  assert.ok(pod.indexOf('data["consent"] as? String == "unknown"') < pod.indexOf('HandsTickTarget(wire: data["tick"], generation: generation)'),
    'the consent check comes before the tick target');
  // 守：量位置的那一份文件＝指令前後主框架的導頁世代一樣；中間換過文件＝世代記 0（tick 一定不點）。
  const action = between(pod, 'private func action(_ command: String, _ arguments: [String: Any]) async -> HandsConnectorAction {', 'nonisolated static func armToken(');
  assert.match(action, /let before = surface\(\)\?\.nativeView\?\.navigationGeneration \?\? 0/);
  assert.match(action, /let after = surface\(\)\?\.nativeView\?\.navigationGeneration \?\? 0\s*let generation = before == after \? after : 0/);
  const target = between(connect, 'init?(wire raw: Any?, generation: UInt64 = 0, minimumHeight: Double = 8) {', 'init(x: Double');
  assert.match(target, /width >= 8, height >= minimumHeight, vw >= 1, vh >= 1, vw <= 10_000, vh <= 10_000,\s*x >= 0, y >= 0, x \+ width <= vw, y \+ height <= vh/);
  assert.match(target, /Set\(object\.keys\)\.isSubset\(of: \["x", "y", "w", "h", "vw", "vh"\]\)/);
  // W183 R10 第二輪（GPT-6 2）：不走裸座標——拿著 Pod、還是量的那一份文件（導頁世代）、沒縮放、畫面大小對得上；快照裡同一個位置
  // 剛好一個控制項；走 CEF 的節點驗證點擊（clickElement：送出之前再核那一點最上面還是它、沒被蓋、位置沒變）；送出那一刻還拿著同一次獨占。
  // 第三輪（GPT-6 發現 2、3）：量完當下就向 CEF 認那一個節點（backendNodeId；認不到＝不代勾），派送時只點它（不依座標重新認領）；
  // 派送前先請網頁腳本核同意內容（變了＝consentChanged，交給使用者）。
  const tick = between(pod, 'func tick(_ target: HandsTickTarget) async -> HandsTickOutcome {', 'nonisolated static func tickControl(');
  // W183 R12（.034 實機：CEF 的畫面快照整頁只有 1 個控制項＝節點驗證永遠過不了、永遠不代勾；主導定的修法）：CEF 認得到＝照舊點那一個節點（加分）；
  // 認不到＝走 DOM 驗證：按之前網頁腳本在同一份文件再驗一次（表單、同意內容一字不差、剛好一格、字對得上、看得見、沒停用、還沒勾）並量位置，
  // 還拿著同一次獨占、同一份文件、畫面大小一樣、沒縮放才用 CEF 真的滑鼠事件點中心（domTick）；點完用 DOM 確認勾上了、Create 能按（tickLanded），沒有＝交回使用者。
  assert.match(tick, /guard let lease = hold, tap\.connection == \.ready, let view = surface\(\)\?\.nativeView, !target\.form\.isEmpty else \{/);
  assert.match(tick, /if let node = target\.node \{/);
  assert.match(tick, /clicked = await domTick\(target, view: view, lease: lease, generation: generation\)/);
  assert.match(tick, /return await tickLanded\(target\.form, view: view, lease: lease, generation: generation\) \? \.clicked : \.notClicked/);
  assert.match(tick, /guard target\.generation != 0, generation == target\.generation, Self\.sameViewport\(view\.bounds\.size, viewport\), view\.zoomLevel == 0 else \{/);
  assert.match(tick, /view\.clickElement\(node\.id, at: point, expectedRect: rect/);
  assert.ok(tick.indexOf('request("connectorConsent"') > 0 && tick.indexOf('request("connectorConsent"') < tick.indexOf('view.clickElement('));
  assert.match(pod, /target\.node = await captureTickNode\(target, lease: lease\)/);
  assert.doesNotMatch(pod, /guard let node = await captureTickNode/, 'a CEF miss is not "not found" any more (W183 R12)');
  assert.match(tick, /guard let self, self\.hold == lease, view\.navigationGeneration == generation else \{ return false \}\s*dispatch\(\)\s*return true/);
  assert.doesNotMatch(code(tick), /evaluateJavaScript|\.checked|dispatchEvent|sendClick\(/);
  // W183 R12：裸座標的點只在 domTick——先請腳本在同一份文件再驗一次、量位置，同一次獨占、同一份文件、畫面大小一樣、沒縮放才送。
  const dom = between(pod, 'private func domTick(', 'nonisolated static func domClickPoint(');
  assert.ok(dom.indexOf('request("connectorTick", ["phase": "aim"') > 0 && dom.indexOf('request("connectorTick", ["phase": "aim"') < dom.indexOf('view.sendClick('));
  assert.match(dom, /guard hold == lease, view\.navigationGeneration == generation,\s*let point = Self\.domClickPoint\(aim, generation: generation, viewSize: view\.bounds\.size, zoomLevel: view\.zoomLevel\) else \{/);
  assert.match(pod, /guard let aim, aim\["status"\] as\? String == "ok", zoomLevel == 0,/);
  // 只點一次；沒勾到＝交給使用者；新的勾選框（checkbox）、警語對不上（warning_changed）＝一句話說原因。
  const flow = between(connect, 'private func tickAndCreate(', 'private func awaitAuthorize(');
  assert.equal((flow.match(/pod\.tick\(/g) || []).length, 1);
  assert.match(connect, /reason == Self\.warningChangedReason \? Self\.warningChangedCardText/);
  assert.match(connect, /reason == Self\.checkboxUnknownReason \? Self\.checkboxUnknownCardText/);
  assert.match(tap, /if \(boxes\.length !== 1 \|\| rec\.zones\.length !== 1 \|\| rec\.zones\[0\]\.box !== boxes\[0\]\) \{ out\.reason = 'checkbox'; return out; \}/);
  // W183 R12（主導 3）：對不上＝照舊 warning_changed、不代勾；多帶那一份（offer：純文字＋連結的字與網域）給卡片顯示全文。
  assert.match(tap, /if \(!consentVersion\(root\)\) \{ out\.reason = 'warning_changed'; out\.offer = consentOffer\(root\); return out; \}/);
  // 認得的警語＝版本化的完整文字白名單（英文照 09-29 截圖；中文沒核實過不放）；關鍵字或相似度的比對不留。
  const versions = between(tap, 'const CONSENT_VERSIONS = [', '];');
  assert.match(versions, /\{ id: 'en-2026-09-29',\s*text: 'New Plugin Icon \(optional\)/);
  assert.doesNotMatch(versions, /[一-鿿]/, 'no unverified Chinese version');
  assert.doesNotMatch(tap, /KNOWN_RISK|RISK_WORDS|knownRisk\(/);
  // R9 的證據鏈照舊（確認的主體從使用者換成 TATWO 的原生點擊）：只收 isTrusted 的點擊、一次性記號。
  assert.match(tap, /if \(e\.isTrusted !== true\) \{\s*if \(type === 'click'\) \{ taint \+= 1;/);
  // 守（R9 的一次性記號，W183 R10 第二輪改成兩步按）：armed 的那一刻表單的確認就用掉（同一個確認再帶一次＝ack_replayed），
  // 真的按（connectorPress）之前再用掉 armed 的記號（第二次＝ack_replayed）；動態反例在 w183-connect 的 two-step press 那一條。
  assert.match(tap, /const armPress = \(owned, button, kind, check\) => \{\s*const token = newMark\(\), accountEpoch = authEpoch;\s*spentMarks\[owned\.mark\] = 'used';/);
  assert.match(tap, /if \(authEpoch !== accountEpoch\) return stale\('account_changed'\);/);
  assert.match(tap, /rec\.armed = null;\s*consume\(\{ mark: t, rec \}\);\s*kpress\(arm\.button\);/);
  for (const label of ['W183 R10 代勾：Pod 說只剩「I understand」那一格＝TATWO 點那一格', 'W183 R10 代勾點不下去：交給你勾', 'W183 R10 點了沒勾到：不再點第二次',
    'W183 R10 第二輪 代勾只點「同一份文件、同一個位置剛好一個」的那個節點', 'W183 R10 第三輪 派送代勾前核到同意內容變了']) {
    assert.ok(r10.includes(label), label);
  }
  const r9 = swift('Facade/HandsConnectR9Acceptance.swift');
  assert.ok(r9.includes('W183 R10 第二輪 Pod 回 consent unknown＝不代勾'), 'decode check: consent unknown / generation stamp / arm token');
  // 自測：警語改了、沒見過的勾選框兩種都跑（卡片一句話說原因）；換位、多個、導頁、別的網站、停用一律不點。
  assert.match(r10, /\("r10-changed", HandsConnectFlow\.warningChangedReason, HandsConnectFlow\.warningChangedCardText\),\s*\("r10-box", HandsConnectFlow\.checkboxUnknownReason, HandsConnectFlow\.checkboxUnknownCardText\)/);
  assert.match(r10, /\("換了位置（量完之後網頁把它移走）", snapshot\(\[control\("cef-12", 20, 430\)\]\)\)/);
});

// ---------- (f) 代填只在綁定頁 ----------

test('(f) auto-fill only on the bound page that the press opened (anchor first, then the page; same page, same parameters, this host); anything else = no fill, no code, the transaction is void', () => {
  // 碼只在主機核對過綁住的那一頁之後才有（onAuthorizePage＋那一頁正在私訊框裡）。
  // W183 R10 第二輪（GPT-6 1）：只有「App 記下錨點之後送出的按、網頁回了按下去」的這一輪才代填；回覆沒回來（pressUnproven）、手動模式＝不代填。
  const pairing = between(connect, 'private func pairing(', 'case .authorized:');
  assert.match(pairing, /let code = onAuthorizePage && presenter\.showsSurface\(first\.frame\.surface\) \? tx\.pairingCode : nil/);
  assert.match(pairing, /let provenFill = pressAnchor != nil && !pressUnproven && !crowdedSinceAnchor && !manualAttempt\s*if let code, provenFill, autoFill == \.notTried \{/);
  // 第三輪（GPT-6 發現 1；主導裁決）：錨點之後、配對頁之前只准一條路——配對頁在 popup＝新開的只有它、而且是 Pod 主框架開的；在主框架＝
  // 沒有新開任何 popup。不是＝不代填、顯示碼（同源的惡意腳本偽造因果屬殘餘）。
  // 第四輪（GPT-6 發現 1）：原生一開窗就算（popupOpened）；frameChanged 在任何處理（關掉、載入中）之前再算一次；不是主框架開的＝不代填。
  const frameChanged = between(connect, 'func frameChanged(_ frame: HandsPodFrame) {', 'private func podLost(');
  assert.ok(frameChanged.indexOf('popupsSinceAnchor.insert(key)') < frameChanged.indexOf('if frame.closed {'), 'counted before the closed/loading branches');
  assert.match(frameChanged, /if let anchor = pressAnchor, observed == nil, frame\.popup, let key = frame\.popupKey, !anchor\.popups\.contains\(key\) \{\s*popupsSinceAnchor\.insert\(key\)\s*if !frame\.openerIsMain \{ nonMainOpenerSinceAnchor = true \}\s*\}/);
  assert.match(connect, /let single = frame\.popup \? \(frame\.openerIsMain && frame\.popupKey\.map \{ popupsSinceAnchor == \[\$0\] \} == true\)\s*: popupsSinceAnchor\.isEmpty\s*if !single \|\| nonMainOpenerSinceAnchor \{ crowdedSinceAnchor = true \}/);
  const opened = between(connect, 'func popupOpened(key: Int, at: Date, openerIsMain: Bool) {', '/// W183 R10 第三輪：要叫 Pod 建立');
  assert.match(opened, /guard let anchor = pressAnchor, observed == nil, !anchor\.popups\.contains\(key\) else \{ return \}\s*popupsSinceAnchor\.insert\(key\)\s*if !openerIsMain \{ nonMainOpenerSinceAnchor = true \}/);
  assert.match(connect, /pod\.onPopupOpened = \{ \[weak self\] key, at, openerIsMain in self\?\.popupOpened\(key: key, at: at, openerIsMain: openerIsMain\) \}/);
  // 正式 Pod：開窗那一刻就登記、通知，開窗者照 CEF 給的（frame->IsMain()）；所有 popup 的畫面都帶著它；預設不是 true。
  assert.match(connect, /var openerIsMain: Bool = false/);
  assert.match(pod, /let entry = registerPopup\(key: key, view: popup, sensitive: sensitive, openerIsMain: popup\.openedByMainFrame\)/);
  assert.match(pod, /popups\[key\] = entry\s*onPopupOpened\?\(key, entry\.openedAt, openerIsMain\)/);
  assert.match(pod, /popup: true, popupKey: key, closed: true,\s*openerIsMain: entry\.openerIsMain\)/);
  assert.match(pod, /popup: true, popupKey: key, source: source, openedAt: openedAt, openerIsMain: openerIsMain\)/);
  const bridgeHeader = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h');
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridgeHeader, /@property\(atomic\) BOOL openedByMainFrame;/);
  assert.match(bridge, /const bool opener_is_main_frame = frame\.get\(\) != nullptr && frame->IsMain\(\);/);
  assert.ok(bridge.indexOf('contained.openedByMainFrame = opener_is_main_frame;') > 0 && bridge.indexOf('contained.openedByMainFrame = opener_is_main_frame;') < bridge.indexOf('contain(contained);'));
  assert.ok(bridge.indexOf('popup.openedByMainFrame = opener_is_main_frame;') > 0 && bridge.indexOf('popup.openedByMainFrame = opener_is_main_frame;') < bridge.indexOf('opener.onPopupCreated(popup)'));
  assert.match(pairing, /let result = await pod\.fillPairingCode\(code, frame: first\.frame, evidence: first\.evidence, publicHost: host\)/);
  // 送了「按」、回覆沒回來（.unknown）：記成來源證明不了；只為了接著等配對頁（顯示碼）才當成按了，代填照 pressUnproven 不做。
  assert.match(connect, /if action == \.unknown \{\s*\/\/[^\n]*\n\s*\/\/[^\n]*\n\s*pressUnproven = true/);
  assert.match(connect, /if action == \.unknown \{ action = \.pressed \}   \/\/ 只為了接著等配對頁（顯示碼）；代填照 pressUnproven 不做/);
  // 錨點：Pod 驅動在送 connectorPress 之前交給流程（主框架的世代與網址、已經開著的 popup）；手動模式沒有錨點。
  const action = between(pod, 'private func action(_ command: String, _ arguments: [String: Any]) async -> HandsConnectorAction {', 'nonisolated static func armToken(');
  assert.ok(action.indexOf('onPressDispatch?(anchor)') > 0 && action.indexOf('onPressDispatch?(anchor)') < action.indexOf('request("connectorPress"'));
  const dispatched = between(connect, 'private func pressDispatched(_ anchor: HandsPressAnchor) {', 'static func isConversationPath(');
  assert.match(dispatched, /guard intent != nil, !manualAttempt, observed == nil else \{ return \}\s*pressAnchor = anchor/);
  // 第三輪（GPT-6 發現 7）：錨點只收這一次按的操作（取消、重連之後晚到的舊操作不收）；沒按下去＝錨點作廢。
  assert.match(dispatched, /guard let expected = pressOperation, anchor\.operation == expected else \{\s*log\("stale press anchor"\)/);
  assert.match(connect, /if action != \.pressed, action != \.unknown \{ dropPressAnchor\(\) \}/);
  // Create（或重新連線）還沒真的送出之前（整個準備期間：沒有錨點、也還沒開始手動等）出現的配對頁＝當場終止、那一筆作廢。
  assert.match(connect, /if intent != nil, !granted, observed == nil, pressAnchor == nil, awaitingSince == nil,\s*Self\.authorizeEvidence\(url, publicHost: publicHost\) != nil \{\s*log\("authorize before create"\)\s*return refuse\(Self\.beforeCreateText, my: runID\)/);
  assert.doesNotMatch(connect, /\bticking\b/, 'the old rule only covered the tick; the anchor covers the whole preparation');
  // 錨點之後：主框架要是比錨點新的一份文件、沒離開過 chatgpt.com；popup 要是錨點那時還沒開的。
  const anchor = between(connect, 'nonisolated static func anchorProblem(', 'private func pressDispatched(');
  assert.match(anchor, /guard let key = frame\.popupKey, !anchor\.popups\.contains\(key\) else \{ return "popup_before_press" \}/);
  assert.match(anchor, /guard frame\.generation > anchor\.mainGeneration else \{ return "not_after_press" \}/);
  assert.match(anchor, /return leftChatGPT \? "left_chatgpt_after_press" : nil/);
  assert.match(connect, /if let why = pressAnchor\.flatMap\(\{ Self\.anchorProblem\(frame, anchor: \$0, leftChatGPT: mainLeftChatGPT\) \}\)\s*\?\? Self\.provenanceProblem\(frame, since: pressAnchor\?\.at \?\? awaitingSince \?\? \.distantFuture\) \{/);
  // Pod 端：每一步之前都核「還是綁住的那一頁」（同一個導頁世代、同一組參數，常數時間比對）；表單只認這台主機的那一張。
  const fill = between(pod, 'func fillPairingCode(', 'private func boundView(');
  assert.match(fill, /view\.navigationGeneration == generation && sameEvidence\(\) && view\.zoomLevel == 0 && Self\.sameViewport\(view\.bounds\.size, viewport\)/);
  assert.match(fill, /return HandsConnectFlow\.authorizeEvidence\(current, publicHost: publicHost\)\.map \{ HandsAuth\.constantTimeEqual\(\$0, evidence\) \} \?\? false/);
  assert.ok((fill.match(/stillBound\(\)/g) || []).length >= 4, 'checked before the snapshot, after it, before every key and before submit');
  const form = between(pod, 'nonisolated static func pairingForm(', 'private nonisolated static func rect(');
  assert.match(form, /let origin = "https:\/\/" \+ publicHost\.lowercased\(\)/);
  assert.match(form, /\(snapshot\["navigationGeneration"\] as\? NSNumber\)\?\.uint64Value == generation/);
  assert.match(form, /guard mine\.count == 1, let fields = mine\[0\]\["fields"\] as\? \[\[String: Any\]\] else \{ return nil \}/);
  assert.match(form, /guard texts\.count == 1, submits\.count == 1/);
  // 別組參數：當場終止（不填、不給碼、那一筆作廢）。
  assert.match(connect, /log\("second authorize page"\)\s*refuse\("配對中途出現另一組授權頁；已停止、沒有顯示碼", my: runID\)/);
  // 碼不進紀錄、診斷：log 只寫固定字，填失敗的原因只留英數代號。
  for (const line of code(connect).match(/log\([^)]*\)/g) ?? []) assert.doesNotMatch(line, /code|pairingCode|evidence/i, line);
  assert.match(connect, /log\("autofill failed \\\(Self\.cleanStep\(why\)\)"\)/);
  assert.doesNotMatch(code(fill), /log\(|NSLog|print\(|NSPasteboard|UserDefaults/);
  for (const label of ['W183 R10 代填：主機核對過綁住的那一頁才給碼', 'W183 R10 Create 之前出現的配對頁：當場終止、不填、不給碼、那一筆作廢',
    'W183 R10 沒綁上（占著窗口的交易不是 Pod 看到的那一頁）：主機不給碼＝不填、不顯示、那一筆作廢', 'W183 R10 代填只認這一頁的這一張表單',
    'W183 R10 手動模式（建立是你自己按的、來源確認不了）：不代填',
    'W183 R10 第二輪 準備期間（Create 還沒送出、不只代勾那一段）冒出的配對頁', 'W183 R10 第二輪 送了 Create、回覆沒回來（unknown）',
    'W183 R10 第二輪 錨點那一刻已經開著的 popup 裡出現的配對頁', 'W183 R10 第二輪 錨點之後主框架離開過 chatgpt.com 再回來才出現的配對頁',
    'W183 R10 第二輪 對照組：錨點（press dispatched）在前、配對頁（authorize observed）在後',
    'W183 R10 第三輪 錨點之後多開了別的 popup', 'W183 R10 第三輪 配對頁所在的 popup 不是 Pod 主框架開的', 'W183 R10 第三輪 對照組：錨點之後剛好一個新 popup',
    'W183 R10 第三輪 取消→重連→舊操作的錨點晚到', 'W183 R10 第三輪 取消→重連→舊的 armed 晚到（真的 Pod 驅動）',
    'W183 R10 第四輪 錨點之後先開的 popup 一直在載入', 'W183 R10 第四輪 錨點之後開的 popup 沒載入完就關了', 'W183 R10 第四輪 真的 Pod 驅動：原生一開窗就通知流程',
    'W183 R10 第四輪 真的 Pod 驅動：錨點之後有 popup 是子框架開的']) {
    assert.ok(r10.includes(label), label);
  }
});

// ---------- (g) 填失敗退回顯示碼 ----------

test('(g) a failed, unaccepted or unproven auto-fill falls back to showing the code (one sentence on the card); never a second fill', () => {
  const pairing = between(connect, 'private func pairing(', 'case .authorized:');
  assert.match(pairing, /case \.failed\(let why\):\s*autoFill = \.failed/);
  assert.match(pairing, /if tx\.attemptsLeft < before \|\| dependencies\.now\(\)\.timeIntervalSince\(at\) > dependencies\.timeouts\.fillSettle \{\s*autoFill = \.failed/);
  assert.match(pairing, /autoFillFailed: autoFill == \.failed,\s*autoFillUnproven: \(pressUnproven \|\| crowdedSinceAnchor\) && !manualAttempt\)\)\s*presenter\.setCodeVisible\(code != nil\)/);
  assert.match(connect, /static let autoFillFailedLine = "TATWO 沒在配對頁填成：照這 8 碼自己打"/);
  // W183 R10 第二輪：來源證明不了（Create 的回覆沒回來）＝不代填，卡片也說一句為什麼要自己打。
  assert.match(connect, /static let autoFillUnprovenLine = "TATWO 確認不了這一頁是這次按下 Create 開的，沒有代填：照這 8 碼自己打"/);
  assert.match(dmView, /if view\.autoFillFailed \|\| view\.autoFillUnproven \{/);
  assert.match(dmView, /Text\(view\.autoFillUnproven \? HandsConnectFlow\.autoFillUnprovenLine : HandsConnectFlow\.autoFillFailedLine\)/);
  assert.match(dmView, /\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.autoFillFailed"\)/);
  for (const label of ['W183 R10 代填找不到欄位（頁面改版）：退回顯示碼', 'W183 R10 代填送了沒被收下（剩的次數變少）：馬上退回顯示碼（只填一次）',
    'W183 R10 代填送出去沒被收下（等太久）：退回顯示碼，不再填第二次']) {
    assert.ok(r10.includes(label), label);
  }
});

// ---------- 文件 ----------

test('docs: contract §3b, threat-model T15, spec and tasks carry R10 and say which old rules it replaces (with the user\'s words)', () => {
  const contract = read('docs/specs/183-chatgpt-hands/contract.md');
  const threat = read('docs/specs/183-chatgpt-hands/threat-model.md');
  const spec = read('docs/specs/183-chatgpt-hands/spec.md');
  const tasks = read('docs/specs/183-chatgpt-hands/tasks.md');
  for (const [name, text] of [['contract', contract], ['threat-model', threat], ['spec', spec], ['tasks', tasks]]) {
    assert.match(text, /W183 R10/, name);
  }
  assert.match(contract, /這邊要勾選也太怪/);
  assert.match(contract, /首版不自動填碼/);
  assert.match(threat, /\| T15 \|[^\n]*W183 R10/);
  assert.match(tasks, /R10/);
  // W183 R10 第二輪（主導裁決 9）：contract §3b／§3d 與 threat-model 照這一輪的做法改寫（來源證據、代勾節點驗證、警語白名單、底線覆蓋面）。
  // 第三輪（主導裁決 C）：前提是 chatgpt.com 被入侵的那幾條寫成明確殘餘，不宣稱來源證據鏈已經完整。
  assert.doesNotMatch(contract + threat + tasks, /照字面做到/);
  assert.match(contract, /前提是 chatgpt\.com 本身被入侵（同源的惡意腳本）時，它可以在錨點之後自己開那一條路/);
  assert.match(contract, /\*\*前提是 chatgpt\.com 本身被入侵（同源的惡意腳本；R9 已定案的殘餘/);
  assert.match(threat, /\| T15 \|[^\n]*殘餘（前提：chatgpt\.com 本身被入侵，同源的惡意腳本/);
  assert.match(tasks, /- \[ \] A 殘餘（不修）：前提 chatgpt\.com 被入侵/);
  assert.match(tasks, /### W183 R10 第四輪/);
  assert.match(threat, /\| T15 \|[^\n]*第四輪（GPT-6 發現 1）/);
  assert.match(threat, /\| T18 \|[^\n]*第四輪（GPT-6 發現 3）/);
  for (const term of ['按 Create 的來源證據', 'HandsPressAnchor', 'connectorPress', '節點驗證的點擊', 'clickElement', '同意內容白名單', 'CONSENT_VERSIONS',
    'sanitizeDependency', '.build/repositories', 'seatbeltPatterns', 'ensureSecretScan', 'quarantine-', 'secret_in_history', '專案根目錄本身是金鑰類資料夾',
    'HandsTradingFloor.classify', 'classification_changed', 'scopeOldGrant',
    // 第三輪
    '只點量完當下記下的那一個節點', 'backendNodeId', '同意內容綁進代勾證據', 'connectorConsent', '一次操作綁到底', '只准一條路', '舊工作區整理',
    'git clone --mirror --no-local', 'O_NOFOLLOW', '執行前隔離', 'TMPDIR', 'classification_pending', 'publicationLock',
    // 第四輪
    'frame->IsMain()', '還原之後重新整理', 'secret_recheck_needed', 'gc.auto=0', '不蓋掉使用者的 Git 工作', 'secret_migration_paused', 'commitSequence']) {
    assert.ok(contract.includes(term), term);
  }
  assert.match(threat, /\| T15 \|[^\n]*W183 R10 第二輪/);
  assert.match(threat, /\| T18 \|[^\n]*W183 R10 第二輪/);
  assert.match(threat, /\| T4 \|[^\n]*第二輪/);
  assert.match(threat, /\| T6 \|[^\n]*W183 R10 第二輪/);
  assert.match(tasks, /### W183 R10 第二輪/);
  assert.match(spec, /W183 R10 第二輪/);
});
