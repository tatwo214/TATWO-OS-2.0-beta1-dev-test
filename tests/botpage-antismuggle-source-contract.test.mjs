import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// BotPageAntiSmuggleSourceTests — Gen-4 U2 anti-smuggle source contract.
// Style: tests/gen3-governance-adapter-source-contract.test.mjs
// Pins the same rg assertions as harness-exam/g4/antismuggle-report.md.

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const srcDir = path.join(
  repoRoot,
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac",
);
const botPagePath = path.join(srcDir, "BotPage.swift");
const botFixturePath = path.join(srcDir, "BotPageFixture.swift");
const chatPagePath = path.join(srcDir, "ChatPage.swift");
const botStatePath = path.join(srcDir, "BotPageState.swift");
const botState = fs.readFileSync(botStatePath, "utf8");
const botPageFiles = [botPagePath, botFixturePath, botStatePath];
const botPage = fs.readFileSync(botPagePath, "utf8");
const botFixture = fs.readFileSync(botFixturePath, "utf8");
// ChatPage.swift was split into topic files (2026-09-02); read the family.
const readChatPageFamily = (dir) => fs.readdirSync(dir)
  .filter((n) => n === "ChatPage.swift" || n.startsWith("ChatPage+"))
  .sort()
  .map((n) => fs.readFileSync(path.join(dir, n), "utf8"))
  .join("\n");
const chatPage = readChatPageFamily(srcDir);

const forbiddenControls = /\b(Toggle|Slider|Stepper|Picker)\s*(\(|\{)|\bNSOpenPanel\b/;
const forbiddenSDKImports = /^\s*(?:@[\w.]+(?:\([^\n]*?\))?\s+)*(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+[^\n]*(?:Runner|Channel|Auth|Sandbox|Gateway|MCP|Line|Discord|Telegram)/m;

function rg(args, files) {
  try {
    const stdout = execFileSync("rg", [...args, ...files], {
      encoding: "utf8",
      cwd: repoRoot,
    });
    return { status: 0, stdout };
  } catch (err) {
    if (err.status === 1) {
      return { status: 1, stdout: err.stdout || "" };
    }
    throw err;
  }
}

function assertNoRgHits(pattern, files, extraArgs = []) {
  const result = rg(["-n", ...extraArgs, pattern], files);
  assert.equal(
    result.status,
    1,
    `expected zero hits for ${pattern}, got:\n${result.stdout}`,
  );
  assert.equal(result.stdout.trim(), "");
}

function slice(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker after ${start}: ${end}`);
  return source.slice(from, to);
}

test("BotPage files exist as a sibling surface, not ChatPageModel", () => {
  assert.equal(fs.existsSync(botPagePath), true);
  assert.equal(fs.existsSync(botFixturePath), true);
  assert.match(botPage, /struct BotPageRootView: View/);
  assert.match(botFixture, /struct BotPageFixture/);
  assert.doesNotMatch(botPage, /ChatPageModel/);
  assert.doesNotMatch(botFixture, /ChatPageModel/);
});

test("no ChatPageModel.send / func send / botDispatcher / gateway.dispatch in BotPage*", () => {
  assertNoRgHits(
    String.raw`ChatPageModel\.send|func send\(|botDispatcher|gateway\.dispatch`,
    botPageFiles,
  );
  assert.doesNotMatch(botPage, /ChatPageModel\.send/);
  assert.doesNotMatch(botFixture, /ChatPageModel\.send/);
  assert.doesNotMatch(botPage, /func send\(/);
  assert.doesNotMatch(botFixture, /func send\(/);
});

test("ChatPage .bot branch does not call send", () => {
  assertNoRgHits(String.raw`ChatPageModel\.send`, [chatPagePath]);
  // `chatSidebar` lost `private` when ChatPage.swift was split (2026-09-02).
  const sidebar = slice(chatPage, "        case .bot:", "    var chatSidebar");
  assert.match(sidebar, /EmptyView\(\)/);
  assert.doesNotMatch(sidebar, /send\s*\(/);
  assert.doesNotMatch(sidebar, /ensureNativeTerminal/);

  const mainBot = slice(
    chatPage,
    "            if model.mode == .bot {",
    "            } else if model.mode == .cli {",
  );
  assert.match(mainBot, /BotPageRootView\.forScene/);
  assert.doesNotMatch(mainBot, /send\s*\(/);
  assert.doesNotMatch(mainBot, /ensureNativeTerminal/);
  assert.doesNotMatch(mainBot, /composer\(/);

  const composerGate = slice(
    chatPage,
    "            if model.mode != .cli, model.mode != .bot {",
    "        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)",
  );
  assert.match(composerGate, /composer\(/);
});

// 4bddddd6 and 0ada09db added approved, view-local skill/permission toggles.
// Pin their complete bindings, rather than banning the approved UI or allowing
// arbitrary Toggle setters. Extra controls and new side effects still fail.
function toggleBindings(source) {
  assert.doesNotMatch(source, /\bToggle\s*\{/);
  return [...source.matchAll(/\bToggle\s*\(/g)].map(match => {
    const start = source.indexOf("(", match.index);
    let depth = 0;
    for (let i = start; i < source.length; i++) {
      if (source[i] === "(") depth++;
      if (source[i] === ")" && --depth === 0) return source.slice(match.index, i + 1).replace(/\s+/g, "");
    }
    assert.fail("unterminated Toggle binding");
  });
}
const approvedToggleBindings = [
  `Toggle(isOn: Binding(
    get: { state.isSkillRegistered(skill.id) },
    set: { on in on ? state.registerSkill(skill.id) : state.unregisterSkill(skill.id) }
  ))`,
  `Toggle("", isOn: Binding(
    get: { state.isPermissionEnabled(botID: info.id, permissionID: row.id) },
    set: { _ in state.togglePermission(botID: info.id, permissionID: row.id) }))`,
].map(value => value.replace(/\s+/g, "")).sort();
function assertFixtureControls(source) {
  assert.doesNotMatch(source, /\b(Slider|Stepper|Picker)\s*(\(|\{)|\bNSOpenPanel\b/);
  assert.deepEqual(toggleBindings(source).sort(), approvedToggleBindings);
}

const approvedStateSetters = [
  `func registerSkill(_ skillID: String) {
    guard let key = pocketBotKey,
          BotPageFixture.allSkills.contains(where: { $0.id == skillID }) else { return }
    var list = registeredSkillIDs[key] ?? []
    guard !list.contains(skillID) else { return }
    list.append(skillID)
    registeredSkillIDs[key] = list
  }`,
  `func unregisterSkill(_ skillID: String) {
    guard let key = pocketBotKey else { return }
    registeredSkillIDs[key]?.removeAll { $0 == skillID }
  }`,
  String.raw`func togglePermission(botID: String, permissionID: String) {
    let key = "\(botID)|\(permissionID)"
    if enabledPermissionKeys.contains(key) { enabledPermissionKeys.remove(key) }
    else { enabledPermissionKeys.insert(key) }
  }`,
];
function assertFixtureStateSetters(source) {
  for (const expected of approvedStateSetters) {
    const signature = expected.slice(0, expected.indexOf("{"));
    const start = source.indexOf(signature);
    assert.notEqual(start, -1, `missing fixture setter ${signature}`);
    let depth = 0;
    let end = source.indexOf("{", start);
    for (; end < source.length; end++) {
      if (source[end] === "{") depth++;
      if (source[end] === "}" && --depth === 0) break;
    }
    assert.equal(source.slice(start, end + 1).replace(/\s+/g, ""), expected.replace(/\s+/g, ""));
  }
}

test("only the two approved fixture-local Toggle bindings are permitted", () => {
  assertFixtureControls(botPage);
  assertFixtureStateSetters(botState);
  assert.doesNotMatch(botState, /\bTask\s*(?:\.|\(|\{)/);
  assertNoRgHits(forbiddenControls.source, [botFixturePath, botStatePath]);
  assert.match(botState, /@Published private\(set\) var registeredSkillIDs: \[String: \[String\]\] = \[:\]/);
  assert.match(botState, /@Published var enabledPermissionKeys: Set<String> = \[\]/);
  assert.match(botState, /BotPageFixture\.allSkills\.contains\(where: \{ \$0\.id == skillID \}\)/);
  assertNoRgHits(String.raw`URLSession|Process\s*\(|ChatCLIProcessRunner|gateway\.|botDispatcher|\.send\s*\(`, botPageFiles);
});

test("control contract rejects a third Toggle and side effects hidden in approved setters", () => {
  for (const mutation of [
    botPage + '\nToggle("extra", isOn: $value)',
    botPage.replace('state.registerSkill(skill.id)', 'runner.start(skill.id)'),
    botPage.replace('state.togglePermission(botID: info.id, permissionID: row.id)', 'UserDefaults.standard.set(true, forKey: "permission")'),
    botPage.replace('state.unregisterSkill(skill.id)', 'state.unregisterSkill(skill.id); execute()'),
    botPage + '\nSlider(value: $value)',
  ]) assert.throws(() => assertFixtureControls(mutation));
  for (const mutation of [
    botState.replace("list.append(skillID)", "runner.start(skillID); list.append(skillID)"),
    botState.replace("enabledPermissionKeys.insert(key)", "grantSystemPermission(key); enabledPermissionKeys.insert(key)"),
    botState.replace("registeredSkillIDs[key]?.removeAll", "persist(); registeredSkillIDs[key]?.removeAll"),
  ]) assert.throws(() => assertFixtureStateSetters(mutation));
});

test("no WKWebView in BotPage files or ChatPage", () => {
  assertNoRgHits(
    String.raw`WKWebView|WKWebViewConfiguration|WebKit`,
    [...botPageFiles, chatPagePath],
  );
});

test("no Line / Discord / Telegram SDK import in BotPage files", () => {
  assertNoRgHits(
    String.raw`^import[[:space:]].*(Line|Discord|Telegram)|LineSDK|DiscordSDK|DiscordKit|TelegramBotSDK|TelegramBot\b`,
    botPageFiles,
  );
});

test("no UserDefaults / FileManager writes in BotPage files", () => {
  assertNoRgHits(
    String.raw`UserDefaults|FileManager|NSOpenPanel|NSSavePanel|\.write\(|createDirectory`,
    botPageFiles,
  );
});

test("fixture ids all use the fixture- prefix", () => {
  const negative = rg(
    ["-n", "--pcre2", String.raw`id:\s*"(?!fixture-)[^"]+"`],
    [botFixturePath],
  );
  assert.equal(negative.status, 1, negative.stdout);
  const ids = [...botFixture.matchAll(/\bid:\s*"([^"]+)"/g)].map((m) => m[1]);
  assert.ok(ids.length >= 20, `expected many fixture ids, got ${ids.length}`);
  for (const id of ids) {
    assert.ok(id.startsWith("fixture-"), `id missing fixture- prefix: ${id}`);
  }
});

test("no runner / gateway / MCP / sandbox service import in BotPage files", () => {
  assertNoRgHits(
    forbiddenSDKImports.source,
    botPageFiles,
    ["--pcre2"],
  );
});

test("onChange of model.mode only starts terminal on .cli", () => {
  assertNoRgHits(String.raw`onChange|ensureNativeTerminal`, botPageFiles);
  const onChange = slice(
    chatPage,
    ".onChange(of: model.mode) { _, newMode in",
    ".onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier]",
  );
  assert.match(
    onChange,
    /if newMode == \.cli, model\.isCLIRuntimeEnabled \{\s*model\.ensureNativeTerminal\(\)/,
  );
  assert.doesNotMatch(onChange, /newMode == \.bot/);
  assert.doesNotMatch(onChange, /newMode != \.chat/);

  const lines = chatPage.split("\n");
  const idx = lines.findIndex((line) =>
    line.includes(".onChange(of: model.mode)"),
  );
  assert.ok(idx >= 0, "onChange(of: model.mode) must exist in the ChatPage family");
  assert.match(lines[idx + 1], /if newMode == \.cli, model\.isCLIRuntimeEnabled/);
  assert.match(lines[idx + 2], /model\.ensureNativeTerminal\(\)/);
  assert.equal(lines[idx + 3].trim(), "}");
});

test("anti-smuggle matchers reject real controls and SDK imports, not helper names or system imports", () => {
  for (const control of ["Toggle", "Slider", "Stepper", "Picker"]) {
    assert.match(`${control}("fixture")`, forbiddenControls);
    assert.match(`SwiftUI.${control}("fixture")`, forbiddenControls);
    assert.match(`${control} { Text("fixture") }`, forbiddenControls);
    assert.doesNotMatch(`func status${control}() {}`, forbiddenControls);
  }
  assert.match("NSOpenPanel()", forbiddenControls);
  for (const sdk of ["Runner", "Channel", "Auth", "Sandbox", "Gateway", "MCP", "Line", "Discord", "Telegram"]) {
    for (const statement of [`import ${sdk}SDK`, `@preconcurrency import ${sdk}SDK`, `public import struct ${sdk}SDK.Client`]) {
      assert.match(statement, forbiddenSDKImports);
    }
  }
  for (const module of ["SwiftUI", "Foundation", "AppKit", "Combine"]) {
    assert.doesNotMatch(`import ${module}`, forbiddenSDKImports);
  }
});
