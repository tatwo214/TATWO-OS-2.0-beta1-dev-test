#!/usr/bin/env node

import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(root, "scripts", "tatwo-local-validation.mjs");
const hostRehearsalScript = path.join(root, "scripts", "tatwo-host-sandbox-rehearsal.mjs");
const hostMcpSmokeScript = path.join(root, "scripts", "tatwo-host-mcp-registration-smoke.mjs");
const workflowsRoot = path.join(root, ".github", "workflows");

const plan = spawnSync(process.execPath, [script, "--plan"], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(plan.status, 0, plan.stderr);
const contract = JSON.parse(plan.stdout);
assert.equal(contract.schema, "TatwoLocalValidationPlanV1");
assert.equal(contract.receiptScope, "one_physical_device_per_receipt");
assert.equal(contract.githubRole, "private_backup_only");
assert.equal(contract.automaticGitHubHostedRunnerRequired, false);
assert.equal(contract.githubActionsUsedForValidation, false);
assert.equal(contract.macOSVirtualMachine.requiredForSourceCandidate, false);
assert.equal(contract.macOSVirtualMachine.requiredBeforeStableInstallerPromotion, true);
assert.ok(contract.deniedActions.includes("does_not_write_/Applications"));
assert.ok(contract.deniedActions.includes("does_not_apply_real_user_data_migration"));
assert.ok(contract.requiredLayers.includes("macos_sandbox_enforcement"));
assert.ok(contract.requiredLayers.includes("final_source_seal"));

const selftest = spawnSync(process.execPath, [script, "--selftest"], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(selftest.status, 0, selftest.stderr);
const selftestReceipt = JSON.parse(selftest.stdout);
assert.equal(selftestReceipt.schema, "TatwoLocalValidationSelftestV1");
assert.equal(selftestReceipt.passed, true);
assert.ok(selftestReceipt.checks.every((check) => check.passed));

const hostRehearsalSource = fs.readFileSync(hostRehearsalScript, "utf8");
const hostMcpSmokeSource = fs.readFileSync(hostMcpSmokeScript, "utf8");
assert.match(
  hostRehearsalSource,
  /const inheritedOuterSandbox = process\.env\.TATWO_OUTER_SANDBOX === "1"/,
  "host rehearsal must recognize that the local gate already placed it inside a macOS sandbox",
);
assert.match(
  hostRehearsalSource,
  /inheritedOuterSandbox\s*\?\s*\[\s*process\.execPath,/s,
  "host rehearsal must reuse the inherited sandbox instead of nesting sandbox-exec",
);
assert.match(
  hostRehearsalSource,
  /const privateReadPath = path\.join\(os\.userInfo\(\)\.homedir, "\.codex"\)/,
  "the inherited-sandbox probe must target the physical user's Codex home, not the fake HOME",
);
assert.match(
  hostRehearsalSource,
  /TATWO_MCP_TOOL_TIMEOUT_MS:\s*String\(hostRehearsalMcpToolTimeoutMS\(\)\)/,
  "cold host rehearsal must give the sandboxed MCP CLI build an explicit cross-device timeout budget",
);
assert.match(
  hostRehearsalSource,
  /TATWO_HOST_REHEARSAL_MCP_TIMEOUT_MS\s*\?\?\s*"240000"/,
  "the parent rehearsal must wait longer than the cold MCP tool build budget",
);
assert.match(
  hostMcpSmokeSource,
  /const requestTimeoutMS = Math\.max\(60000, mcpToolTimeoutMS \+ 30000\)/,
  "the stdio client request timer must not expire before the MCP tool timeout",
);
assert.match(
  hostMcpSmokeSource,
  /const child = spawn\(process\.execPath,/,
  "sandboxed MCP smoke must launch Node by absolute execPath instead of PATH lookup",
);

const workflowFiles = fs.existsSync(workflowsRoot)
  ? fs.readdirSync(workflowsRoot).filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  : [];
assert.equal(contract.authority, "local_dual_device_validation");
const policySource = fs.readFileSync(path.join(root, "docs/protocol/LOCAL_VALIDATION_POLICY.md"), "utf8");
const policy = JSON.parse(policySource.match(/```json\n([\s\S]*?)\n```/)[1]);
assert.equal(policy.scope, "local_validation_authority");
assert.equal(policy.replacesDeviceReceipt, false);
assert.equal(policy.grantsPromotion, false);
assert.deepEqual(policy.workflows.map(row => row.path), [".github/workflows/update-policy.yml"]);

function verifySupplementalWorkflows(files, read = name => fs.readFileSync(path.join(workflowsRoot, name))) {
  assert.deepEqual([...files].sort(), ["update-policy.yml"], "unknown or missing hosted workflow requires policy review");
  const source = read("update-policy.yml");
  assert.equal(createHash("sha256").update(source).digest("hex"), policy.workflows[0].sha256,
    "only the reviewed read-only supplemental workflow is permitted; do not grant CI release authority");
  assert.match(String(source), /permissions:\s*contents: read/);
  assert.doesNotMatch(String(source), /secrets\.|write-all|contents: write|pull_request_target|workflow_run|gh release|productionPromotionGranted/);
}
verifySupplementalWorkflows(workflowFiles);
assert.throws(() => verifySupplementalWorkflows([...workflowFiles, "publish.yml"]));
assert.throws(() => verifySupplementalWorkflows([]));
const approvedWorkflow = fs.readFileSync(path.join(workflowsRoot, "update-policy.yml"), "utf8");
for (const changed of [
  approvedWorkflow.replace("contents: read", "contents: write"),
  approvedWorkflow.replace("pull_request:", "pull_request_target:"),
  approvedWorkflow + "\n  publish:\n    steps:\n      - run: gh release create v1\n",
]) assert.throws(() => verifySupplementalWorkflows(workflowFiles, () => changed));
