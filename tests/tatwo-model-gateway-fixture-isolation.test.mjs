import assert from "node:assert/strict";
import { once } from "node:events";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { createSandbox, source, verifyFixture } from "./helpers/model-gateway-historical-fixture.mjs";

const externalRoot = verifyFixture();
// Keep even mutation-test copies in private staging, never an inherited TMPDIR
// that a full-suite runner might place inside its checkout.
const evidence = fs.mkdtempSync(path.join(path.dirname(externalRoot), "gateway-isolation-"));
const scratch = () => fs.mkdtempSync(path.join(evidence, "case-"));

test("external fixture rejects absent, relative and in-checkout directories", () => {
  for (const input of ["", "relative", undefined]) {
    // Pass an empty value rather than using the real default environment.
    assert.throws(() => verifyFixture(input ?? ""), /must explicitly name an absolute/);
  }
  assert.throws(() => verifyFixture(fs.realpathSync(new URL(".", import.meta.url))), /outside the checkout/);
});

test("external fixture fails closed when either historical file is missing", () => {
  for (const missing of Object.keys(source.files)) {
    const root = scratch();
    for (const name of Object.keys(source.files)) {
      if (name !== missing) fs.copyFileSync(path.join(externalRoot, name), path.join(root, name));
    }
    assert.throws(() => verifyFixture(root), /ENOENT/);
  }
});

test("external fixture rejects a changed byte in either historical file", () => {
  for (const changed of Object.keys(source.files)) {
    const root = scratch();
    for (const name of Object.keys(source.files)) {
      fs.copyFileSync(path.join(externalRoot, name), path.join(root, name));
    }
    fs.appendFileSync(path.join(root, changed), "\n");
    assert.throws(() => verifyFixture(root), /historical SHA256 mismatch/);
  }
});

test("external fixture rejects symlinked entrypoints", () => {
  const root = scratch();
  fs.symlinkSync(path.join(externalRoot, "server.js"), path.join(root, "server.js"));
  assert.throws(() => verifyFixture(root), /regular file, not a symlink/);
});

test("Seatbelt denies private-file substitutes, outbound, other executables and wildcard bind; children inherit isolation",
  { timeout: 30_000 }, async () => {
    const root = scratch();
    const outside = scratch();
    const canary = path.join(outside, "auth.json");
    const config = path.join(outside, "config.json");
    const dotEnv = path.join(outside, ".env");
    for (const file of [canary, config, dotEnv]) fs.writeFileSync(file, "SYNTHETIC-PRIVATE-CANARY");
    const mockClaude = path.join(root, "mock-claude.cjs");
    const mockGrok = path.join(root, "mock-grok.cjs");
    for (const file of [mockClaude, mockGrok]) fs.writeFileSync(file,
      "#!/usr/bin/env -S node --openssl-config=/dev/null\nconsole.log('MOCK_OK');\n", { mode: 0o700 });
    const sandbox = createSandbox(root, externalRoot, mockClaude, mockGrok);
    let connections = 0;
    const listener = net.createServer((socket) => { connections += 1; socket.destroy(); });
    listener.listen(0, "127.0.0.1");
    await once(listener, "listening");
    const port = listener.address().port;
    // The sandbox allows inbound only on this exact port. Outbound to even this
    // already-listening loopback service must fail, without trying an external IP.
    const probe = `
const fs = require("node:fs"), net = require("node:net"), cp = require("node:child_process");
const result = {};
const attempt = fn => { try { fn(); return "ALLOWED"; } catch (e) { return e.code; } };
result.files = ${JSON.stringify([canary, config, dotEnv])}.map(file => attempt(() => fs.readFileSync(file)));
result.list = attempt(() => fs.readdirSync(${JSON.stringify(outside)}));
result.write = attempt(() => fs.writeFileSync(${JSON.stringify(path.join(outside, "write"))}, "x"));
result.exec = cp.spawnSync("/usr/bin/true").error?.code || "ALLOWED";
result.chdir = attempt(() => { process.chdir("/tmp"); process.chdir(${JSON.stringify(root)}); });
const mock = cp.spawnSync(${JSON.stringify(mockClaude)}, [], {cwd:"/tmp",encoding:"utf8"});
result.mock = {code:mock.status,error:mock.error?.code,stdout:mock.stdout,stderr:mock.stderr};
result.env = process.env;
const child = cp.spawnSync(process.execPath, ["-e",
  'const fs=require("node:fs"),net=require("node:net");const r={};try{fs.readFileSync(process.argv[1]);r.file="ALLOWED"}catch(e){r.file=e.code}' +
  'const s=net.createConnection({host:"127.0.0.1",port:${port}});s.on("error",e=>{r.network=e.code;console.log(JSON.stringify(r))});' +
  's.on("connect",()=>{r.network="ALLOWED";s.destroy();console.log(JSON.stringify(r))});',
  ${JSON.stringify(canary)}], {encoding:"utf8"});
result.descendant = child.status === 0 ? child.stdout.trim() : "CHILD_FAILED";
let pending = 2;
const done = () => { if (--pending === 0) console.log(JSON.stringify(result)); };
const socket = net.createConnection({host:"127.0.0.1",port:${port}});
socket.once("error", e => { result.outbound = e.code; done(); });
socket.once("connect", () => { result.outbound = "ALLOWED"; socket.destroy(); done(); });
const server = net.createServer();
server.once("error", e => { result.wildcard = e.code; done(); });
server.listen(0,"0.0.0.0", () => { result.wildcard = "ALLOWED"; server.close(done); });
`;
    // Seed only a synthetic variable in the parent; never inspect host credentials.
    const prior = process.env.TATWO_GATEWAY_HOST_CANARY;
    process.env.TATWO_GATEWAY_HOST_CANARY = "SYNTHETIC-ENV-CANARY";
    let child;
    try {
      child = sandbox.launch(["-e", probe], port);
      let stdout = "", stderr = "";
      child.stdout.on("data", (chunk) => { stdout += chunk; });
      child.stderr.on("data", (chunk) => { stderr += chunk; });
      const timer = setTimeout(() => child.kill("SIGKILL"), 15_000);
      const [code, signal] = await once(child, "close");
      clearTimeout(timer);
      assert.equal(code, 0, `sandbox probe failed (${signal}): ${stderr}`);
      const result = JSON.parse(stdout);
      assert.equal(result.chdir, "ALLOWED", JSON.stringify(result));
      assert.equal(result.mock.code, 0, JSON.stringify(result.mock));
      assert.equal(result.mock.stdout.trim(), "MOCK_OK");
      assert.deepEqual(result.env, {
        ...sandbox.env, MODEL_GATEWAY_HOST: "127.0.0.1", MODEL_GATEWAY_PORT: String(port),
      }, "child must receive only the explicit clean environment");
      assert.deepEqual(result.files, ["EPERM", "EPERM", "EPERM"]);
      assert.deepEqual(JSON.parse(result.descendant), { file: "EPERM", network: "EPERM" });
      for (const key of ["list", "write", "exec", "outbound", "wildcard"]) {
        assert.equal(result[key], "EPERM", `${key}: ${JSON.stringify(result)}`);
      }
      assert.equal(connections, 0);
      fs.writeFileSync(path.join(evidence, "isolation-proof.json"), JSON.stringify({
        files: result.files, list: result.list, write: result.write, exec: result.exec,
        descendant: result.descendant, outbound: result.outbound, wildcard: result.wildcard,
        cleanEnvironment: true, acceptedConnections: connections,
      }, null, 2));
      console.log(`isolation evidence: ${evidence}`);
    } finally {
      if (prior === undefined) delete process.env.TATWO_GATEWAY_HOST_CANARY;
      else process.env.TATWO_GATEWAY_HOST_CANARY = prior;
      if (child && child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await new Promise((resolve) => listener.close(resolve));
    }
  });
