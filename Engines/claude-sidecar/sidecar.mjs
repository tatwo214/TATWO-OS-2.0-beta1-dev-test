// tatwo2 Claude sidecar：一個常駐 Agent SDK session。
// stdin 每行一個 JSON 指令，stdout 每行一個 JSON 事件。SDK 訊息原樣轉發（ev:"sdk"），不重造。
//   in : {op:"send", text, uuid?} | {op:"steer", text, uuid, targetTurnUUID, attachments?} | {op:"permission", id, allow, message?} | {op:"interrupt"} | {op:"model", model} | {op:"close"}
//   out: {ev:"sdk", msg} | {ev:"permission_request", id, tool, input, title?, description?} | {ev:"error", message} | {ev:"closed"}
import { claudeModels } from '../model-capabilities.mjs';
import { query } from '@anthropic-ai/claude-agent-sdk';
import readline from 'node:readline';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const catalogOnly = argv.includes('--catalog-only');
const cwd = flag('--cwd', process.cwd());
const resume = flag('--resume', undefined);
const model = flag('--model', undefined);
const permissionMode = flag('--permission-mode', 'default');
const systemPrompt = flag('--system-prompt', undefined);
const browserMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../browser-mcp/server.mjs');
const osMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../os-mcp/server.mjs');
// W113：本機由 App 經環境變數交付（內含 GitHub token，不能進 argv）；讀完立刻從環境刪掉，子程序不會繼承整包設定。
const mcpConfigText = process.env.TATWO2_MCP_CONFIG ?? flag('--mcp-config', undefined);
delete process.env.TATWO2_MCP_CONFIG;
let mcpConfig;
try {
  mcpConfig = mcpConfigText ? JSON.parse(mcpConfigText) : undefined;
} catch (error) {
  process.stdout.write(JSON.stringify({ ev: 'error', message: `bad --mcp-config json: ${String(error)}` }) + '\n');
  process.exit(1);
}

const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');

// W113：Claude CLI 的 MCP 設定會整包出現在它的 argv（--mcp-config）。憑證改放進這個程序的環境別名，
// 設定裡只留 ${別名}；CLI 啟動 MCP 伺服器時自己展開（實測 inline --mcp-config 也會展開）。
function secretURL(value, urlOnly = false) {
  const raw = String(value ?? ''); let text;
  const direct = /(?:^|[\s=:"',])(?:sk-|ghp_|github_pat_|xox|AKIA)|(?:[?;&]|\s)(?:password|passwd|pwd)\s*=\s*[^;&\s]+/i;
  try { text = decodeURIComponent(raw); } catch { return urlOnly === true || raw.includes('://') || direct.test(raw); }
  if (direct.test(text)) return true;
  const expression = /[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]*/gi;
  const urls = text.match(expression) ?? [];
  if ((raw.match(expression) ?? []).some(url => url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '').split(/[/?#]/, 1)[0].includes('@'))) return true;
  if (urlOnly === true && (urls.length !== 1 || urls[0] !== text)) return true;
  return urls.some(url => {
    if (typeof URL === 'function') { try { new URL(url); } catch { return true; } }
    const rest = url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, ''), end = rest.search(/[/?#]/);
    const authority = end < 0 ? rest : rest.slice(0, end), tail = end < 0 ? '' : rest.slice(end);
    if (!/^(?:[^/@?#\s]+@)?(?:\[[0-9a-f:.]+\]|[^:/?#\s\[\]]+)(?::[0-9]{1,5})?$/i.test(authority)) return true;
    if (Number(authority.split(']').at(-1).split(':').at(-1)) > 65535) return true;
    return authority.includes('@') || tail.split(/[/?#;&=]/).some(part => /key|token|secret|password|passwd|pwd|auth|sig|^(?:sk-|ghp_|github_pat_|xox|AKIA)/i.test(part));
  });
}
let mcpSecretIndex = 0;
const mcpSourceEnvironment = { ...process.env };
for (const [name, server] of Object.entries(mcpConfig?.servers ?? {})) {
  if ((server?.url != null && secretURL(server.url, true)) || (server?.args ?? []).some(secretURL)) { delete mcpConfig.servers[name]; continue; }
  if (!server) continue;
  for (const field of ['env', 'headers', 'http_headers']) {
    for (const [key, value] of Object.entries(server[field] ?? {})) {
      if (typeof value !== 'string') continue;
      const alias = `TATWO2_MCP_SECRET_${mcpSecretIndex++}`;
      // CLI 只展開一次；來源的環境引用要先展開，才包進別名。
      process.env[alias] = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g,
        (match, variable, fallback) => mcpSourceEnvironment[variable] ?? fallback ?? match);
      server[field][key] = '${' + alias + '}';
    }
  }
}
const validPermissionModes = new Set(['default', 'acceptEdits', 'bypassPermissions', 'readOnly']);
if (!validPermissionModes.has(permissionMode)) {
  emit({ ev: 'error', message: `unknown permission mode ${permissionMode}` });
  process.exit(1);
}
const readOnly = permissionMode === 'readOnly' || catalogOnly;
const readOnlyTools = ['Read', 'Grep', 'Glob'];

const inbox = [];
let wake = null;
let closed = false;
async function* prompts() {
  for (;;) {
    if (inbox.length) { const m = inbox.shift(); if (m === null) return; yield m; continue; }
    if (closed) return;
    await new Promise((r) => { wake = r; });
  }
}
const push = (m) => { inbox.push(m); const w = wake; wake = null; w?.(); };

let activeTurn;
let stopping = false;
const outstanding = new Set();
const submitted = new Set();
const steering = new Map();
const acknowledge = (id, accepted, message, unknown = false) => {
  const target = steering.get(id);
  if (!target) return;
  steering.delete(id);
  emit({ ev: 'sdk', msg: { type: 'system', subtype: 'steer_result',
    request_id: id, target_turn_id: target, accepted, message, unknown } });
};
const rejectSteer = (cmd, message) => emit({ ev: 'sdk', msg: {
  type: 'system', subtype: 'steer_result', request_id: cmd.uuid,
  target_turn_id: cmd.targetTurnUUID, accepted: false, message,
} });

const pending = new Map();
const canUseTool = readOnly ? async (tool, input) => (
  readOnlyTools.includes(tool)
    ? { behavior: 'allow', updatedInput: input }
    : { behavior: 'deny', message: '唯讀工作只允許 Read、Grep、Glob；不能提升權限。' }
) : (tool, input, o) => new Promise((resolve) => {
  pending.set(o.requestId, { resolve, input });
  emit({ ev: 'permission_request', id: o.requestId, tool, input, title: o.title, description: o.description, toolUseID: o.toolUseID, suggestions: o.suggestions });
  o.signal.addEventListener('abort', () => { if (pending.delete(o.requestId)) resolve({ behavior: 'deny', message: 'aborted' }); });
});

const q = query({
  prompt: prompts(),
  options: {
    ...(process.env.TATWO2_CLAUDE_BIN ? { pathToClaudeCodeExecutable: process.env.TATWO2_CLAUDE_BIN } : {}),
    cwd, resume, model, permissionMode: readOnly ? 'dontAsk' : permissionMode,
    // Match the native dispatch maximum plus socket grace; never expire at 2m.
    env: { ...process.env, MCP_TOOL_TIMEOUT: '1830000', CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT: '1830000' },
    includePartialMessages: true,
    extraArgs: { 'replay-user-messages': null },
    settingSources: readOnly || process.env.TATWO2_MANAGED_NO_MEMORY === '1' ? [] : ['user', 'project'],
    canUseTool,
    // Normal sessions retain selected MCPs and built-in bridges; read-only never mounts them.
    mcpServers: readOnly ? {} : Object.fromEntries(Object.entries({ ...(mcpConfig?.servers ?? {}), tatwo2_browser: { command: 'node', args: [browserMCPServer], env: { ...(process.env.TATWO2_BROWSER_SOCKET ? { TATWO2_BROWSER_SOCKET: process.env.TATWO2_BROWSER_SOCKET } : {}) } }, tatwo2_os: { command: 'node', args: [osMCPServer], env: { ...(process.env.TATWO2_OS_SOCKET ? { TATWO2_OS_SOCKET: process.env.TATWO2_OS_SOCKET } : {}) } } }).map(([name, server]) => [name, { ...server, ...(mcpConfig?.threadID ? { env: { ...server.env, TATWO2_THREAD_ID: mcpConfig.threadID } } : {}) }])),
    ...(mcpConfig?.servers || readOnly ? { strictMcpConfig: true } : {}),
    // Apply on new and resumed queries alike. `allowedTools` only auto-approves;
    // `tools` is the native built-in tool surface restriction.
    ...(readOnly ? {
      tools: readOnlyTools,
      hooks: {},
      plugins: [],
      skills: [],
      agents: {},
      settings: {
        disableAllHooks: true,
        disableBundledSkills: true,
        disableSkillShellExecution: true,
        disableClaudeAiConnectors: true,
      },
    } : {}),
    ...(systemPrompt ? { systemPrompt: { type: 'preset', preset: 'claude_code', append: systemPrompt } } : {}),
    stderr: (line) => emit({ ev: 'stderr', line }),
  },
});

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let cmd; try { cmd = JSON.parse(line); } catch { return emit({ ev: 'error', message: 'bad json: ' + line }); }
  try {
    switch (cmd.op) {
      case 'steer':
      case 'send': {
        if (stopping) { if (cmd.op === 'steer') rejectSteer(cmd, '這一輪正在停止，請重新送出'); break; }
        if (cmd.op === 'steer') {
          if (!activeTurn || cmd.targetTurnUUID !== activeTurn) {
            rejectSteer(cmd, '這一輪已結束或正在停止，請重新送出');
            break;
          }
          if (!cmd.uuid || submitted.has(cmd.uuid)) {
            rejectSteer(cmd, '重複或無效的插話識別碼');
            break;
          }
          steering.set(cmd.uuid, activeTurn);
        } else {
          activeTurn = cmd.uuid;
          submitted.clear();
        }
        submitted.add(cmd.uuid);
        outstanding.add(cmd.uuid);
        if (cmd.effort !== undefined || cmd.serviceTier !== undefined) {
          if (typeof q.applyFlagSettings !== 'function') throw new Error('SDK does not support native effort/speed controls');
          await q.applyFlagSettings({
            ...(cmd.effort !== undefined ? {effortLevel: cmd.effort} : {}),
            ...(cmd.serviceTier !== undefined ? {fastMode: cmd.serviceTier === 'priority'} : {}),
          });
        }
        if (stopping) break;
        const atts = Array.isArray(cmd.attachments) ? cmd.attachments : [];
        if (atts.length === 0) {
          push({ type: 'user', message: { role: 'user', content: cmd.text }, parent_tool_use_id: null, uuid: cmd.uuid });
          break;
        }
        const blocks = [];
        const notes = [];
        for (const p of atts) {
          const ext = path.extname(p).toLowerCase();
          const mime = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }[ext];
          try {
            if (mime) {
              blocks.push({ type: 'image', source: { type: 'base64', media_type: mime, data: fs.readFileSync(p).toString('base64') } });
            } else {
              notes.push(`附件檔案：${p}`);
            }
          } catch (e) { notes.push(`附件讀取失敗：${p}`); }
        }
        const text = [cmd.text, ...notes].filter(Boolean).join('\n');
        if (text) blocks.push({ type: 'text', text });
        push({ type: 'user', message: { role: 'user', content: blocks }, parent_tool_use_id: null, uuid: cmd.uuid });
        break;
      }
      case 'permission': {
        const p = pending.get(cmd.id); if (!p) return emit({ ev: 'error', message: 'unknown permission id ' + cmd.id });
        pending.delete(cmd.id);
        p.resolve(cmd.allow ? { behavior: 'allow', updatedInput: cmd.updatedInput ?? p.input } : { behavior: 'deny', message: cmd.message ?? '使用者拒絕' });
        break;
      }
      case 'interrupt': {
        if (stopping) break;
        stopping = true;
        inbox.length = 0;
        // Interrupt alone leaves queued inputs runnable. Resume in a fresh
        // sidecar after closing this query so Stop also stops insertions.
        try { await q.interrupt(); }
        catch (e) { emit({ ev: 'stderr', line: String(e) }); }
        q.close();
        for (const id of steering.keys()) acknowledge(id, false, '已停止，插話送達狀態待確認', true);
        emit({ ev: 'sdk', msg: { type: 'result', subtype: 'cancelled',
          client_turn_id: activeTurn, is_error: false, result: '' } });
        emit({ ev: 'closed' });
        process.exit(0);
        break;
      }
      case 'model': await q.setModel(cmd.model); break;
      case 'mcp_status': {
        const servers = await q.mcpServerStatus();
        emit({ ev: 'mcp_status', servers });
        break;
      }
      case 'close': closed = true; push(null); break;
      default: emit({ ev: 'error', message: 'unknown op ' + cmd.op });
    }
  } catch (e) { emit({ ev: 'error', message: String(e?.stack || e) }); }
});
rl.on('close', () => { closed = true; push(null); });

(async () => {
  if (typeof q.supportedModels === 'function') {
    try {
      const reported = await q.supportedModels(), models = claudeModels(reported);
      emit({ev:'sdk',msg:{type:'system',subtype:'model_catalog',engine:'claude',
        identity:process.env.TATWO2_ENGINE_IDENTITY ?? 'unknown',source:'Agent SDK 0.3.280 supportedModels()', models, defaultModel:models.find((_, i) => reported[i]?.value === 'default')?.model}});
    } catch (error) { emit({ev:'stderr',line:`SDK 模型查詢失敗，使用標示的備援：${String(error?.message || error)}`}); }
  } else { emit({ev:'stderr',line:'SDK 0.3.280 supportedModels() 不可用，使用標示版本的備援表。'}); }
  if (catalogOnly) { closed = true; push(null); q.close(); rl.close(); emit({ev:'closed'}); process.exit(0); }
  for await (const msg of q) {
    if (stopping) continue;
    // Replay confirms receipt, not completion. UUIDs cover coalesced inputs.
    const answered = msg.user_message_uuids ?? (msg.user_message_uuid ? [msg.user_message_uuid] : []);
    if (msg.type === 'result' && answered.length && !answered.some(id => outstanding.has(id))) continue;
    if (msg.type === 'user' && msg.isReplay && !msg.parent_tool_use_id) acknowledge(msg.uuid, true);
    if (!msg.parent_tool_use_id) for (const id of answered) acknowledge(id, true);
    if (msg.type === 'result') {
      if (msg.is_error) {
        for (const id of steering.keys()) acknowledge(id, false, '回合失敗，插話送達狀態待確認', true);
        emit({ ev: 'sdk', msg: { ...msg, client_turn_id: activeTurn } });
        q.close();
        break;
      }
      if (answered.length) {
        for (const id of answered) outstanding.delete(id);
      } else if (outstanding.size <= 1 && steering.size === 0) {
        outstanding.clear(); // Ordinary turns from older producers.
      } else {
        // Do not guess which insertion an older producer answered.
        for (const id of steering.keys()) acknowledge(id, false, '引擎未回報插話識別碼，請確認回覆', true);
        emit({ ev: 'sdk', msg: { ...msg, client_turn_id: activeTurn,
          is_error: true, result: '引擎未回報插話回覆的識別碼；請確認對話後重新送出。' } });
        q.close();
        break;
      }
      if (outstanding.size > 0 || msg.queued_turn_count > 0) {
        emit({ ev: 'sdk', msg: { type: 'system', subtype: 'turn_continued', client_turn_id: activeTurn } });
        continue;
      }
    }
    emit({ ev: 'sdk', msg: { ...msg, ...(activeTurn ? { client_turn_id: activeTurn } : {}) } });
    if (msg.type === 'result') activeTurn = undefined;
  }
  if (stopping) return;
  emit({ ev: 'closed' });
  process.exit(0);
})().catch((e) => { if (stopping) return; emit({ ev: 'error', message: String(e?.stack || e) }); process.exit(1); });
