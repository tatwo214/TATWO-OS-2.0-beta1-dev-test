// W104：「變更收據」原本接的是空殼（替身面板＋永遠回傳空的讀取函式）。這裡驗真的讀取元件與接線。
import test from 'node:test';
import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

test('接線：空殼移除、面板換成新元件、頂列鈕只在有變更時出現', () => {
  assert.doesNotMatch(read('Facade/Tatwo2PlumbingStubs.swift'), /struct DiffReviewView/);
  const model = read('Facade/ChatPageModel.swift');
  assert.doesNotMatch(model, /func loadWorkspaceDiff\(\) -> TatwoParsedDiff \{ \.init\(files: \[\]\) \}/);
  assert.match(model, /Task\.detached\(priority: \.userInitiated\) \{ WorkspaceChangeReader\.read\(workdir: workdir\) \}/);   // git 不在主執行緒跑
  assert.match(model, /guard let self, self\.workspaceChangeGeneration == generation else \{ return \}/);                  // 切走的結果丟掉
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.match(panels, /ChatWorkspaceChangesView\(load: \{ await model\.loadWorkspaceChanges\(\) \}/);
  assert.match(panels, /if let summary = model\.workspaceChangeSummary \{\s*Button \{ applyRightPanelInteraction\(\.toggleDiff\) \}/);
  const page = read('Chat/ChatPage.swift');
  assert.match(page, /\.onChange\(of: model\.isRunning\) \{ _, running in if !running \{ model\.refreshWorkspaceChangeSummary\(\) \} \}/);
  const reader = read('Facade/WorkspaceChangeReader.swift');
  assert.match(reader, /environment\["GIT_OPTIONAL_LOCKS"\] = "0"/);   // 只讀，不搶 index.lock
  const view = read('New/ChatWorkspaceChangesView.swift');
  for (const text of ['目前沒有未提交的變更', '這個工作資料夾不是 git 專案', '讀不到變更']) assert.ok(view.includes(text), text);
});

test('讀取元件：非 git、乾淨、有變更（含未追蹤的新檔）各自回報正確', () => {
  const work = testScratch('w104-changes-');
  const parent = join(work, 'parent repo'); mkdirSync(parent);
  const fixtures = join(parent, 'fixtures'); mkdirSync(fixtures);
  const hooks = join(work, 'empty-hooks'); mkdirSync(hooks);
  // TMPDIR may itself live in a checkout. Fence only these subprocesses, not
  // production discovery: a nested working directory must still find its repo.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  Object.assign(env, {
    GIT_CEILING_DIRECTORIES: realpathSync(fixtures),
    GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0',
  });
  const git = (dir, ...args) => {
    const result = spawnSync('/usr/bin/git', ['-C', dir, '-c', 'user.name=fixture',
      '-c', 'user.email=fixture\x40example.invalid', '-c', 'commit.gpgsign=false',
      '-c', `core.hooksPath=${hooks}`, ...args], { encoding: 'utf8', env, timeout: 10_000 });
    assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.error ?? ''}\n${result.stderr}`);
    return result;
  };
  git(parent, 'init', '-q', '--template=');
  const plain = join(fixtures, 'plain'); mkdirSync(plain);
  const discovery = ceiling => spawnSync('/usr/bin/git', ['-C', plain, 'rev-parse', '--show-toplevel'],
    { encoding: 'utf8', env: { ...env, GIT_CEILING_DIRECTORIES: ceiling }, timeout: 10_000 });
  const inherited = discovery('');
  assert.equal(inherited.status, 0, inherited.stderr);
  assert.equal(realpathSync(inherited.stdout.trim()), realpathSync(parent), 'counterexample: unfenced plain inherits parent repo');
  const isolated = discovery(env.GIT_CEILING_DIRECTORIES);
  assert.equal(isolated.status, 128, isolated.stderr);
  writeFileSync(join(work, 'discovery.log'), `unfenced=${inherited.status}\n${inherited.stdout}fenced=${isolated.status}\n${isolated.stderr}`);
  const repo = join(fixtures, 'repo'); mkdirSync(repo);
  git(repo, 'init', '-q', '--template=');
  writeFileSync(join(repo, 'a.txt'), 'one\ntwo\nthree\n');
  git(repo, 'add', '.'); git(repo, 'commit', '-q', '-m', 'base');
  const clean = join(fixtures, 'clean'); mkdirSync(clean);
  git(clean, 'init', '-q', '--template='); writeFileSync(join(clean, 'k.txt'), 'x\n'); git(clean, 'add', '.'); git(clean, 'commit', '-q', '-m', 'base');
  writeFileSync(join(repo, 'a.txt'), 'one\nTWO\nthree\nfour\n');
  writeFileSync(join(repo, 'new.txt'), 'hello\n');
  const nested = join(repo, 'nested'); mkdirSync(nested);
  const preserved = [join(repo, '.git/index'), join(clean, '.git/index'), join(repo, 'a.txt'), join(repo, 'new.txt')]
    .map(file => [file, readFileSync(file)]);
  writeFileSync(join(work, 'main.swift'), `
import Foundation
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + " " + detail); if !ok { exit(1) } }
let a = WorkspaceChangeReader.read(workdir: CommandLine.arguments[1])
check("non-git", a.state == .notGit)
let b = WorkspaceChangeReader.read(workdir: CommandLine.arguments[2])
check("clean", b.state == .clean && b.fileCount == 0, "\\(b.state)")
let c = WorkspaceChangeReader.read(workdir: CommandLine.arguments[3])
check("changed", c.state == .changed, "\\(c.state)")
check("one tracked file", c.diff.files.count == 1 && c.diff.files[0].newPath == "a.txt", "\\(c.diff.files.map(\\.newPath))")
check("counts", c.added == 2 && c.removed == 1, "+\\(c.added) -\\(c.removed)")
check("untracked listed", c.untracked == ["new.txt"], "\\(c.untracked)")
check("summary", WorkspaceChangeReader.summary(workdir: CommandLine.arguments[3]) == WorkspaceChangeSummary(files: 2, added: 2, removed: 1))
check("summary nil when clean", WorkspaceChangeReader.summary(workdir: CommandLine.arguments[2]) == nil)
check("missing dir", WorkspaceChangeReader.read(workdir: CommandLine.arguments[5]).state == .notGit)
check("nested directory still discovers its repository", WorkspaceChangeReader.read(workdir: CommandLine.arguments[4]) == c)
`);
  const build = spawnSync('swiftc', ['-O', join(root, 'App/Sources/Tatwo2/Facade/WorkspaceChangeReader.swift'),
    join(root, 'App/Sources/Tatwo2/Chat/TatwoDiffHunkParser.swift'), join(work, 'main.swift'), '-o', join(work, 'probe')], { encoding: 'utf8' });
  writeFileSync(join(work, 'compile.log'), `${build.stdout ?? ''}${build.stderr ?? ''}`);
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(work, 'probe'), [plain, clean, repo, nested, join(fixtures, 'missing')], { encoding: 'utf8', env, timeout: 30_000 });
  writeFileSync(join(work, 'result.log'), `${run.stdout ?? ''}${run.stderr ?? ''}`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal((run.stdout.match(/^PASS /gm) ?? []).length, 10, run.stdout);
  for (const [file, bytes] of preserved) assert.deepEqual(readFileSync(file), bytes, `reader mutated ${file}`);
});
