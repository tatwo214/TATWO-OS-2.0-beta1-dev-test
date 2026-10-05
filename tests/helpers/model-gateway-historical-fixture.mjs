// Test-only loader. Never discovers an installed gateway or reads a live HOME.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const source = JSON.parse(fs.readFileSync(
  new URL("../fixtures/model-gateway-continuation-20260803-v1/SOURCE.json", import.meta.url), "utf8",
));

export function verifyFixture(directory = process.env[source.environment]) {
  assert.ok(directory && path.isAbsolute(directory),
    `${source.environment} must explicitly name an absolute private fixture directory`);
  const root = fs.realpathSync(directory);
  assert.ok(fs.statSync(root).isDirectory(), "external fixture must be a directory");
  const repo = fs.realpathSync(fileURLToPath(new URL("../../", import.meta.url)));
  assert.ok(root !== repo && !root.startsWith(repo + path.sep),
    "historical private source must remain outside the checkout");
  for (const [name, expected] of Object.entries(source.files)) {
    const file = path.join(root, name);
    assert.ok(fs.lstatSync(file).isFile(), `${name} must be a regular file, not a symlink`);
    const data = fs.readFileSync(file);
    assert.equal(createHash("sha256").update(data).digest("hex"), expected.sha256,
      `${name}: historical SHA256 mismatch`);
    assert.equal(createHash("sha1").update(`blob ${data.length}\0`).update(data).digest("hex"),
      expected.blob, `${name}: historical Git blob mismatch`);
  }
  return root;
}

export function parseMachOLoadCommands(text) {
  const blocks = text.split(/^Load command \d+\s*$/m).slice(1);
  assert.ok(blocks.length, "cannot parse Mach-O load commands; refusing fallback");
  const dependencies = [];
  const rpaths = [];
  for (const block of blocks) {
    const command = block.match(/^\s*cmd (LC_\w+)\s*$/m)?.[1];
    assert.ok(command, "malformed Mach-O load command");
    if (command === "LC_RPATH") {
      const value = block.match(/^\s*path (.+) \(offset \d+\)\s*$/m)?.[1];
      assert.ok(value, "malformed LC_RPATH");
      rpaths.push(value);
    } else if (["LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
      "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"].includes(command)) {
      const value = block.match(/^\s*name (.+) \(offset \d+\)\s*$/m)?.[1];
      assert.ok(value, `malformed ${command}`);
      dependencies.push(value);
    }
    // LC_ID_DYLIB is this image's install name, not another dependency.
  }
  return { dependencies, rpaths };
}

function readMachO(file) {
  const architecture = { arm64: "arm64", x64: "x86_64" }[process.arch];
  assert.ok(architecture, "unsupported Node architecture");
  const result = spawnSync("/usr/bin/otool", ["-arch", architecture, "-l", file], {
    env: { PATH: "/usr/bin:/bin" }, encoding: "utf8", timeout: 10_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  assert.equal(result.status, 0, "cannot determine Node dylibs; refusing unsandboxed fallback");
  return parseMachOLoadCommands(result.stdout);
}

// Expand paths using the image that DECLARED them, never cwd or host DYLD_*.
function imagePath(value, image, executable) {
  const expanded = value
    .replace(/^@loader_path(?=\/|$)/, () => path.dirname(image))
    .replace(/^@executable_path(?=\/|$)/, () => path.dirname(executable));
  assert.ok(path.isAbsolute(expanded), `unsupported Mach-O path: ${value}`);
  return path.normalize(expanded);
}

// Only the runtime binary and its exact non-system dylibs are readable, not an
// entire Homebrew prefix or user-managed Node installation directory. readImage
// is injectable for deterministic negative tests; production always uses otool.
export function runtimeFiles(node, readImage = readMachO) {
  node = fs.realpathSync(node);
  const found = new Set();
  const visited = new Set();
  const visit = (file, inheritedRpaths = []) => {
    const real = fs.realpathSync(file);
    found.add(file);
    found.add(real);
    let link = path.join(fs.realpathSync(path.dirname(file)), path.basename(file));
    while (fs.lstatSync(link).isSymbolicLink()) {
      found.add(link);
      link = path.resolve(path.dirname(link), fs.readlinkSync(link));
    }
    if (visited.has(real)) return;
    visited.add(real);
    const image = readImage(real);
    // dyld searches the requesting image's runpaths before its loader chain.
    // Ancestor entries are already expanded in their declaring image's context.
    const rpaths = [...new Set([
      ...image.rpaths.map((value) => imagePath(value, real, node)),
      ...inheritedRpaths,
    ])];
    for (const name of image.dependencies) {
      let dependency;
      if (name.startsWith("@rpath/")) {
        for (const dir of rpaths) {
          const candidate = path.resolve(dir, name.slice("@rpath/".length));
          try {
            assert.ok(fs.statSync(candidate).isFile(), "rpath target must be a regular file");
            dependency = candidate;
            break; // Exact first existing image, not an allowance for every search directory.
          } catch (error) {
            if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
          }
        }
        assert.ok(dependency, `unresolved Mach-O dependency ${name} in ${real}; no rpath fallback`);
      } else {
        dependency = imagePath(name, real, node);
      }
      if (dependency.startsWith("/usr/lib/") || dependency.startsWith("/System/Library/")) continue;
      visit(dependency, rpaths);
    }
  };
  visit(node);
  return [...found];
}

export function createSandbox(root, externalRoot, mockClaude, mockGrok) {
  assert.equal(process.platform, "darwin", "macOS Seatbelt required; no skip or unsandboxed fallback");
  assert.ok(fs.existsSync("/usr/bin/sandbox-exec"), "sandbox-exec required");
  root = fs.realpathSync(root);
  const node = fs.realpathSync(process.execPath);
  const libraries = runtimeFiles(node);
  const home = path.join(root, "home");
  for (const rel of ["home", "home/codex", "home/claude", "home/.grok",
    "home/.config", "home/.cache", "home/.local/share", "tmp", "os"]) {
    fs.mkdirSync(path.join(root, rel), { recursive: true, mode: 0o700 });
  }
  const env = Object.freeze({
    PATH: path.dirname(node),
    HOME: home,
    CFFIXED_USER_HOME: home,
    CODEX_HOME: path.join(home, "codex"),
    CLAUDE_CONFIG_DIR: path.join(home, "claude"),
    GROK_HOME: path.join(home, ".grok"),
    GROK_REAL_HOME: home,
    GROK_ISOLATED_HOME: home,
    GROK_AUTH_SOURCE: path.join(home, ".grok", "absent-auth.json"),
    XDG_CONFIG_HOME: path.join(home, ".config"),
    XDG_CACHE_HOME: path.join(home, ".cache"),
    XDG_DATA_HOME: path.join(home, ".local/share"),
    TMPDIR: path.join(root, "tmp"),
    TMP: path.join(root, "tmp"),
    TEMP: path.join(root, "tmp"),
    LANG: "C",
    OPENSSL_CONF: "/dev/null",
    TATWO_OS_ROOT: path.join(root, "os"),
    TATWO_OS_CONTEXT: "0",
    GATEWAY_CONTEXT_GUARD: "0",
    GATEWAY_HEARTBEAT_MS: "50",
    CLAUDE_TIMEOUT_MS: "5000",
    GROK_TIMEOUT_MS: "5000",
    CLAUDE_COMMAND: mockClaude,
    GROK_COMMAND: mockGrok,
    GROK_USE_ISOLATED_HOME: "0",
    GROK_MOCK_SESSION_STATE_JSON: JSON.stringify({
      session_id_sha256: "mock-grok-session-sha256",
      summary_session_id_matches: true,
      request_id_consistent: true,
      summary_current_model_id: "grok-4.6",
      turn_started_model_id: "grok-4.6",
      turn_ended_outcome: "success",
      turn_number: 1,
    }),
  });
  const readFiles = [...libraries, "/usr/bin/env",
    ...Object.keys(source.files).map((name) => path.join(externalRoot, name))];
  const ancestors = new Set(["/", "/tmp", "/private/tmp"]);
  for (const file of [...readFiles, root, mockClaude, mockGrok]) {
    for (let dir = path.dirname(file); dir !== "/"; dir = path.dirname(dir)) ancestors.add(dir);
  }
  function launch(args, port, scenario) {
    assert.ok(Number.isInteger(port) && port > 0 && port < 65536);
    assert.ok(scenario === undefined || [
      "exact_tool", "unattested", "result_usage_only", "fallback", "raw_tool_without_schema",
    ].includes(scenario), "only known mock scenarios may vary; no arbitrary child environment");
    // Recheck immutable bytes before every launch.
    verifyFixture(externalRoot);
    const params = [];
    const literal = (value) => {
      const key = `P${params.length}`;
      params.push([key, value]);
      return `(literal (param "${key}"))`;
    };
    const subtree = (value) => literal(value).replace("(literal ", "(subpath ");
    const profile = `(version 1)
(deny default)
(allow process-fork)
(allow process-exec ${[node, "/usr/bin/env", mockClaude, mockGrok].map(literal).join(" ")})
(allow process-info* (target self))
(allow signal (target children) (target self))
(allow sysctl-read (sysctl-name-prefix "hw.") (sysctl-name-prefix "machdep.cpu.")
  ${["kern.ostype", "kern.osrelease", "kern.osrevision", "kern.osversion", "kern.version",
    "kern.osproductversion", "kern.osvariant_status", "kern.iossupportversion",
    "kern.secure_kernel", "kern.maxfiles", "kern.maxfilesperproc", "kern.usrstack64",
    "kern.hostname", "security.mac.lockdown_mode_state", "sysctl.proc_cputype",
    "sysctl.proc_translated"].map((key) => `(sysctl-name "${key}")`).join(" ")})
(allow file-read* (subpath "/usr/lib") (subpath "/usr/share")
  (subpath "/System/Library") (subpath "/System/Volumes/Preboot/Cryptexes")
  (subpath "/private/var/db/timezone") (literal "/private/etc/localtime")
  (literal "/dev/urandom") (literal "/dev/random")
  ${readFiles.map(literal).join(" ")})
(allow file-read-metadata ${[...ancestors].map(literal).join(" ")})
(allow file-read-data (literal "/"))
(allow file-read* file-write* ${subtree(root)})
(allow file-read* file-write-data (literal "/dev/null"))
(allow network-bind network-inbound (local tcp "localhost:${port}"))
(deny network-outbound)
`;
    const sandboxArgs = ["-p", profile];
    for (const [key, value] of params) sandboxArgs.push("-D", `${key}=${value}`);
    return spawn("/usr/bin/sandbox-exec", [...sandboxArgs, node, "--openssl-config=/dev/null", ...args], {
      cwd: root,
      env: {
        ...env,
        MODEL_GATEWAY_HOST: "127.0.0.1",
        MODEL_GATEWAY_PORT: String(port),
        ...(scenario === undefined ? {} : { MOCK_CLAUDE_SCENARIO: scenario }),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
  }
  return { launch, home, env, root };
}

// Embedded in both actual CLI mocks: validate the environment received through
// the historical gateway's two distinct child-spawn paths, not just the helper.
export function mockEnvironmentGuard(root) {
  return `
const assert = require("node:assert/strict");
const path = require("node:path");
const home = ${JSON.stringify(path.join(fs.realpathSync(root), "home"))};
assert.equal(process.env.HOME, home);
for (const key of ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "GROK_REAL_HOME",
  "GROK_ISOLATED_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"]) {
  if (process.env[key] !== undefined)
    assert.ok(process.env[key] === home || process.env[key].startsWith(home + path.sep), key);
}
for (const key of ["NODE_OPTIONS", "NODE_PATH", "DYLD_INSERT_LIBRARIES", "HTTP_PROXY",
  "HTTPS_PROXY", "ALL_PROXY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "MINIMAX_API_KEY",
  "TATWO_GATEWAY_HOST_CANARY"])
  assert.equal(process.env[key], undefined, key + " leaked into mock");
`;
}
