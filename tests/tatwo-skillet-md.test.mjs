import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(repositoryRoot, "scripts/tatwo-skillet-md.py");
const osImage = path.join(repositoryRoot, "scripts/tatwo-os-image.py");

// 測試一律用暫存的家目錄、不寫各家引擎的預設位置：2026-09-25 入口 skillet.md 被蓋成種子，這支工具的預設路徑就是真的入口。
const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-home-"));
function run(args, extra = {}) {
  return spawnSync("python3", [tool, ...args], {
    encoding: "utf8",
    ...extra,
    env: {
      ...process.env,
      ...(extra.env || {}),
      HOME: fakeHome,
      TATWO_OS_ROOT: path.join(fakeHome, "no-entry"),
      TATWO_SKILLET_MD_NO_DEFAULT_WRAPPERS: "1",
    },
  });
}

test("skillet-md selftest keeps vendor SKILL.md and refuses unsafe paths", () => {
  const result = run(["--support", fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-selftest-")), "selftest"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /selftest=passed/);
});

test("consumer cannot local-unify skillet.md", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-consumer-"));
  const result = run(["--support", work, "unify"], {
    env: { ...process.env, TATWO_OS_IMAGE_CONSUMER: "1" },
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /consumer cannot local-unify/);
});

test("unify archives a proposal without rewriting curated skillet.md or vendor skills", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-unify-"));
  const osRoot = path.join(work, "os");
  const runtime = path.join(work, "runtime");
  const vendor = path.join(runtime, "tatwo-ultrawork", "SKILL.md");
  fs.mkdirSync(osRoot, { recursive: true });
  fs.writeFileSync(path.join(osRoot, "os.md"), "# os\n");
  fs.mkdirSync(path.dirname(vendor), { recursive: true });
  fs.writeFileSync(vendor, "KEEP_TATWO\n");
  const installed = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--wrappers", path.join(runtime, "skillet", "SKILL.md"),
    "install",
  ], {
    env: {
      ...process.env,
      TATWO_SKILLS_RUNTIME_ROOT: runtime,
      TATWO_SKILLET_SOURCE_ROOT: "",
    },
  });
  assert.equal(installed.status, 0, installed.stderr + installed.stdout);
  const before = fs.readFileSync(path.join(osRoot, "skillet.md"), "utf8");
  const packaged = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--export", path.join(work, "outgoing"),
    "--device", "laptop",
    "package",
  ]);
  assert.equal(packaged.status, 0, packaged.stderr);
  const inbox = path.join(work, "skillet-md", "inbox", "laptop", "one");
  fs.cpSync(path.join(work, "outgoing"), inbox, { recursive: true });
  fs.writeFileSync(path.join(inbox, "skillet.md"), `${before}\n# laptop note\n`);
  const unified = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--wrappers", path.join(runtime, "skillet", "SKILL.md"),
    "--inbox", path.join(work, "skillet-md", "inbox"),
    "unify",
  ], {
    env: {
      ...process.env,
      TATWO_DATA_SYNC_ROLE: "host",
      TATWO_SKILLS_RUNTIME_ROOT: runtime,
    },
  });
  assert.equal(unified.status, 0, unified.stderr + unified.stdout);
  assert.equal(fs.readFileSync(path.join(osRoot, "skillet.md"), "utf8"), before);
  assert.equal(fs.readFileSync(vendor, "utf8"), "KEEP_TATWO\n");
  assert.match(fs.readFileSync(path.join(work, "skillet-md", "INDEX.md"), "utf8"), /laptop/);
  assert.equal(
    fs.readFileSync(path.join(runtime, "skillet", "SKILL.md"), "utf8"),
    before,
  );
});

test("os-image default OS skill slot is skillet not tatwo-ultrawork", () => {
  const source = fs.readFileSync(osImage, "utf8");
  assert.match(source, /skills-runtime\/skillet/);
  assert.doesNotMatch(source, /skills-runtime\/tatwo-ultrawork/);
  assert.doesNotMatch(source, /\/skills\/tatwo-ultrawork\b/);
});

test("the bare seed never replaces a curated skillet, and linked wrappers stay links", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-guard-"));
  const osRoot = path.join(work, "os");
  fs.mkdirSync(osRoot, { recursive: true });
  fs.writeFileSync(path.join(osRoot, "os.md"), "# os\n");
  const canonical = path.join(osRoot, "skillet.md");
  fs.writeFileSync(canonical, "---\nname: skillet\n---\n# curated\n- keep me\n");
  const curated = fs.readFileSync(canonical, "utf8");
  const seedDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-seed-"));
  const seeded = run(["--support", seedDir, "--os-root", path.join(seedDir, "os"), "--canonical", path.join(seedDir, "os", "skillet.md"), "install"]);
  assert.equal(seeded.status, 0, seeded.stderr);
  const pulled = run(["--support", work, "--os-root", osRoot, "--canonical", canonical, "--source", path.join(seedDir, "os", "skillet.md"), "pull"]);
  assert.equal(pulled.status, 2, pulled.stdout);
  assert.match(pulled.stderr, /refused to overwrite .* bare seed/);
  assert.equal(fs.readFileSync(canonical, "utf8"), curated);
  const wrapperDir = path.join(work, "engine", "skillet");
  fs.mkdirSync(wrapperDir, { recursive: true });
  const link = path.join(wrapperDir, "SKILL.md");
  fs.symlinkSync(canonical, link);
  const mirrored = run(["--support", seedDir, "--os-root", path.join(seedDir, "os"), "--canonical", path.join(seedDir, "os", "skillet.md"), "--wrappers", link, "install"]);
  assert.equal(mirrored.status, 0, mirrored.stderr);
  assert.ok(fs.lstatSync(link).isSymbolicLink(), "wrapper link must stay a link");
  assert.equal(fs.readFileSync(canonical, "utf8"), curated);
});
