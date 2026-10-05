import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { parseMachOLoadCommands, runtimeFiles } from "./helpers/model-gateway-historical-fixture.mjs";

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "gateway-rpath-")));
const file = (relative, data = "") => {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, data);
  return target;
};
const image = (dependencies = [], rpaths = []) => ({ dependencies, rpaths });

test("Mach-O parser keeps LC_RPATH spaces/order and excludes LC_ID_DYLIB", () => {
  assert.deepEqual(parseMachOLoadCommands(`
sample:
Load command 0
          cmd LC_ID_DYLIB
      cmdsize 48
         name @rpath/libnode.147.dylib (offset 24)
Load command 1
          cmd LC_RPATH
      cmdsize 64
         path @loader_path/with spaces (offset 12)
Load command 2
          cmd LC_RPATH
      cmdsize 48
         path @executable_path/../lib (offset 12)
Load command 3
          cmd LC_LOAD_DYLIB
      cmdsize 48
         name @rpath/libdependency.dylib (offset 24)
`), image(["@rpath/libdependency.dylib"], ["@loader_path/with spaces", "@executable_path/../lib"]));
});

test("unresolved @rpath fails closed even if a same-name library exists beside node", () => {
  const node = file("missing/bin/node");
  file("missing/bin/libnode.147.dylib");
  for (const rpaths of [[], ["@executable_path/../absent"]]) {
    assert.throws(() => runtimeFiles(node, () => image(["@rpath/libnode.147.dylib"], rpaths)),
      /unresolved Mach-O dependency.*no rpath fallback/);
  }
});

test("relative or recursively-tokenized LC_RPATH is rejected, never searched from cwd", () => {
  const node = file("invalid/bin/node");
  for (const value of ["../lib", "@rpath/nested", "@unknown/lib"]) {
    assert.throws(() => runtimeFiles(node, () => image(["@rpath/libnode.dylib"], [value])),
      /unsupported Mach-O path/);
  }
});

test("malformed or missing otool load-command output fails closed", () => {
  for (const output of ["not a Mach-O file", "Load command 0\n cmd LC_RPATH\n cmdsize 32\n",
    "Load command 0\n cmd LC_LOAD_DYLIB\n cmdsize 48\n"]) {
    assert.throws(() => parseMachOLoadCommands(output), /cannot parse|malformed/);
  }
});

test("rpath directory and broken symlink cannot become file permissions", () => {
  const node = file("non-file/bin/node");
  const target = path.join(root, "non-file/lib/libnode.dylib");
  fs.mkdirSync(target, { recursive: true });
  assert.throws(() => runtimeFiles(node, () => image(["@rpath/libnode.dylib"], ["@executable_path/../lib"])),
    /rpath target must be a regular file/);
  fs.symlinkSync(path.join(root, "absent.dylib"), path.join(root, "non-file/lib/broken.dylib"));
  assert.throws(() => runtimeFiles(node, () => image(["@rpath/broken.dylib"], ["@executable_path/../lib"])),
    /unresolved Mach-O dependency/);
});

test("runpath order resolves only the first existing exact file, not all candidate directories", () => {
  const node = file("order/bin/node");
  const selected = file("order/first/libnode.dylib");
  const unselected = file("order/second/libnode.dylib");
  const files = runtimeFiles(node, (target) => target === node
    ? image(["@rpath/libnode.dylib"], ["@loader_path/../first", "@loader_path/../second"])
    : image());
  assert.deepEqual(new Set(files), new Set([node, selected]));
  assert.ok(!files.includes(unselected));
  assert.ok(files.every((target) => fs.statSync(target).isFile()));
});

test("real Mach-O: executable and loader LC_RPATH, inherited runpaths, dylib ID and symlink resolve to exact files",
  { timeout: 30_000 }, () => {
    assert.equal(process.platform, "darwin", "real Mach-O validation requires macOS, no skip");
    const project = path.join(root, "real image with spaces");
    for (const dir of ["bin", "lib/leaf", "shared"]) fs.mkdirSync(path.join(project, dir), { recursive: true });
    const leaf = file("real image with spaces/leaf.c", "int leaf(void) { return 1; }\n");
    const inherited = file("real image with spaces/inherited.c", "int inherited(void) { return 2; }\n");
    const bridge = file("real image with spaces/bridge.c",
      "extern int leaf(void); extern int inherited(void); int bridge(void) { return leaf() + inherited(); }\n");
    const main = file("real image with spaces/main.c", "extern int bridge(void); int main(void) { return bridge(); }\n");
    const compile = (args) => {
      const result = spawnSync("/usr/bin/clang", args, {
        env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
        encoding: "utf8", timeout: 15_000,
      });
      assert.equal(result.status, 0, result.stderr || result.error?.message);
    };
    const leafLib = path.join(project, "lib/leaf/libleaf.dylib");
    const inheritedLib = path.join(project, "shared/libinherited.dylib");
    const bridgeLib = path.join(project, "lib/libbridge.1.dylib");
    const bridgeLink = path.join(project, "lib/libbridge.dylib");
    const node = path.join(project, "bin/node");
    compile(["-dynamiclib", leaf, "-install_name", "@rpath/libleaf.dylib", "-o", leafLib]);
    compile(["-dynamiclib", inherited, "-install_name", "@rpath/libinherited.dylib", "-o", inheritedLib]);
    compile(["-dynamiclib", bridge, leafLib, inheritedLib, "-install_name", "@rpath/libbridge.dylib",
      "-Wl,-rpath,@loader_path/leaf", "-o", bridgeLib]);
    fs.symlinkSync("libbridge.1.dylib", bridgeLink);
    compile([main, bridgeLink, "-Wl,-rpath,@executable_path/../lib",
      "-Wl,-rpath,@executable_path/../shared", "-o", node]);
    const resolved = runtimeFiles(node);
    assert.deepEqual(new Set(resolved), new Set([node, bridgeLink, bridgeLib, leafLib, inheritedLib]));
    assert.ok(resolved.every((target) => fs.statSync(target).isFile()));
    const missingRpath = path.join(project, "bin/node-without-rpath");
    compile([main, bridgeLink, "-o", missingRpath]);
    assert.throws(() => runtimeFiles(missingRpath), /unresolved Mach-O dependency.*no rpath fallback/,
      "an actual Mach-O with no LC_RPATH must not guess the adjacent library location");
    // No synthetic binary is run. Header inspection is enough to prove resolution.
    const architecture = process.arch === "arm64" ? "arm64" : "x86_64";
    for (const binary of [node, bridgeLib]) {
      const headers = spawnSync("/usr/bin/otool", ["-arch", architecture, "-l", binary],
        { env: { PATH: "/usr/bin:/bin" }, encoding: "utf8", timeout: 10_000 });
      assert.equal(headers.status, 0, headers.stderr);
      fs.writeFileSync(`${binary}.headers.txt`, headers.stdout);
    }
    fs.writeFileSync(path.join(project, "resolved.json"), JSON.stringify(resolved, null, 2));
    console.log(`real Mach-O header evidence: ${project}`);
  });
