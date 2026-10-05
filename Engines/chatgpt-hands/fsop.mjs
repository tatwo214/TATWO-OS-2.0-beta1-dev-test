// W183 R1／R1b：ChatGPT 手腳的檔案小幫手（只用 Node 內建模組）。
//
// 只由 TATWO OS App 在 Seatbelt 沙盒裡啟動：stdin 一個 JSON 請求、stdout 一個 JSON 回覆。
// App 已先檢查過路徑（第一道）；這裡再檢查一次（第二道）：
// - 路徑只收 root 底下的相對路徑，不收 `..`、絕對路徑、控制字元；
// - 每一段都用 lstat 看：中間不能是捷徑；檔案用 O_NOFOLLOW 開、必須是一般檔、連結數 1（硬連結可能指到外面）；
// - 寫入：踩到保護規則就拒絕（任何一層、大小寫都算：.git、.gitattributes、.gitmodules、.tatwo2、.claude、.codex、.agents、
//   .cursor、.vscode、.mcp.json、AGENTS.md、CLAUDE.md、GEMINI.md、.cursorrules、.windsurfrules、.github/copilot-instructions.md；
//   .github 資料夾本身不能新建）；同資料夾先寫暫存檔再 rename（不會寫一半）。
// - write_file 要 create_only 或 expected_sha256、edit_file 要 expected_sha256（樂觀鎖：別人先改了就拒絕）；
//   apply_patch 全有或全無（中途失敗就把已寫的還原）。
// - read 回行號、總行數、整個檔的 sha256；list／search 固定排序、cursor 翻頁、complete。
// - 秘密行（W183 R1b）：先看整個檔再切頁——私鑰區段（BEGIN 到 END，沒有 END 就到檔尾）、整行像金鑰內文的 base64、
//   行尾是 Bearer 的下一行開頭那個字，一律遮蔽；搜尋不比對被遮蔽的行（不能用搜尋一個字一個字猜）。
// - apply_patch 還原失敗（W183 R1b）：不說「什麼都沒改」；回 patch_partially_applied、列出可能被改的檔，備份留在暫存區。
// 真正的邊界是沙盒：就算這支程式有洞，也寫不出工作區、讀不到秘密、連不上網路。
// - W183 R10 底線 A（金鑰類檔案）：路徑任何一段是金鑰類（.env*、credentials*、id_*、*.pem、*.key、鑰匙圈匯出、.ssh/…）＝
//   read 拒絕、list 不列、search 不看（在翻頁之前就拿掉：總數、還有沒有下一頁都不透露它們在不在）。清單跟 App 的
//   HandsSecretFiles（Facade/HandsFloors.swift）同一份（tests/w183-one-press.test.mjs 比對兩邊一樣）。
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROTECTED_NAMES = ['.git', '.gitattributes', '.gitmodules', '.tatwo2', '.claude', '.codex', '.agents', '.cursor', '.vscode',
  '.mcp.json', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.cursorrules', '.windsurfrules'];
export const PROTECTED_PATHS = ['.github/copilot-instructions.md'];
export const GUARDED_DIRECTORIES = ['.github'];
const PROTECTED = new Set(PROTECTED_NAMES.map(name => name.toLowerCase()));
const SKIP_DIRS = new Set(['.git', 'node_modules', '.build', '.tatwo2', 'DerivedData']);
// W183 R10 底線 A：金鑰類檔案（不分大小寫；任何一段對上＝整條路徑都算）。改清單要跟 HandsSecretFiles 一起改。
// W183 R10 第二輪：補上 wallet.dat、*.wallet、secret*／secrets*／.secrets*、apikey*／api_key*／api-key*、service-account*、mnemonic*、seed*、*.tfvars。
export const SECRET_NAMES = ['.netrc', '.git-credentials', '.pypirc', '.npmrc', '.dockercfg', '.pgpass', '.htpasswd', 'wallet.dat'];
export const SECRET_PREFIXES = ['.env', 'credentials', 'id_', 'secret', 'secrets', '.secrets', 'apikey', 'api_key', 'api-key',
  'service-account', 'mnemonic', 'seed'];
export const SECRET_SUFFIXES = ['.pem', '.key', '.p12', '.pfx', '.p8', '.ppk', '.jks', '.keystore', '.keychain', '.keychain-db',
  '.crt', '.cer', '.der', '.kdbx', '.asc', '.gpg', '.wallet', '.tfvars'];
export const SECRET_DIRECTORIES = ['.ssh', '.gnupg', '.aws', '.docker', '.kube', '.azure', '.password-store'];
export function isSecretName(raw) {
  const name = String(raw ?? '').toLowerCase();
  if (!name) return false;
  if (SECRET_NAMES.includes(name) || SECRET_DIRECTORIES.includes(name)) return true;
  if (SECRET_PREFIXES.some(prefix => name.startsWith(prefix))) return true;
  return SECRET_SUFFIXES.some(suffix => name.endsWith(suffix));
}
export const isSecretPath = parts => parts.some(isSecretName);
const LIMITS = {
  request: 4 * 1024 * 1024,
  readFile: 8 * 1024 * 1024,
  returnBytes: 200_000,
  writeBytes: 2 * 1024 * 1024,
  listPage: 500,
  listEntries: 20_000,
  searchPage: 100,
  searchMatches: 2000,
  searchFiles: 20_000,
  searchFileBytes: 1024 * 1024,
  lineChars: 400,
};

class OpError extends Error {
  constructor(code, detail) { super(code); this.code = code; this.detail = detail; }
}
const fail = (code, detail) => { throw new OpError(code, detail); };
const sha256 = buffer => crypto.createHash('sha256').update(buffer).digest('hex');

function checkRoot(root) {
  if (typeof root !== 'string' || !path.isAbsolute(root)) fail('root_invalid');
  let real;
  try { real = fs.realpathSync(root); } catch { fail('root_missing'); }
  if (real !== root) fail('root_not_canonical');
  if (!fs.lstatSync(root).isDirectory()) fail('root_not_directory');
  return root;
}

/** 保護規則（大小寫都算）：任何一段是保護名稱、結尾是 .github/copilot-instructions.md、或（要新建的）.github 資料夾本身。 */
export function isProtected(parts, { creatingLast = true } = {}) {
  const lowered = parts.map(part => part.toLowerCase());
  if (lowered.some(part => PROTECTED.has(part))) return true;
  const joined = lowered.join('/');
  if (PROTECTED_PATHS.some(item => joined === item.toLowerCase() || joined.endsWith('/' + item.toLowerCase()))) return true;
  if (creatingLast && lowered.length && GUARDED_DIRECTORIES.includes(lowered[lowered.length - 1])) return true;
  return false;
}

export function splitPath(raw, { forWrite }) {
  const value = raw ?? '';
  if (typeof value !== 'string') fail('path_invalid');
  if (Buffer.byteLength(value) > 1024) fail('path_too_long');
  if (/[\u0000-\u001f\u007f]/.test(value)) fail('path_has_control_characters');
  if (value.startsWith('/') || value.startsWith('~')) fail('path_must_be_relative');
  const parts = value.split('/').filter(part => part !== '' && part !== '.');
  if (parts.includes('..')) fail('path_escapes_workspace');
  if (forWrite) {
    if (parts.length === 0) fail('path_required');
    if (isProtected(parts)) fail('protected_path', parts.join('/'));
    // W183 R10 第二輪：金鑰類的路徑也不給寫（新建、改、刪、改名；沙盒規則另外擋）。
    if (isSecretPath(parts)) fail('secret_file_refused');
  }
  return parts;
}

/** 逐段 lstat；create=true 時建立還不存在的中間資料夾（要新建的資料夾也不能踩到保護規則）；
 *  allowMissing=true 時中間資料夾不存在也回 stat=null。回傳 { abs, stat, created }（不存在時 stat 為 null）。 */
function walk(root, parts, { create = false, allowMissing = false } = {}) {
  let current = root;
  const created = [];
  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    const last = index === parts.length - 1;
    let stat = null;
    try { stat = fs.lstatSync(current); } catch (error) { if (error.code !== 'ENOENT') fail('path_unreadable'); }
    if (stat === null) {
      if (last) return { abs: current, stat: null, created };
      if (allowMissing && !create) return { abs: path.join(root, ...parts), stat: null, created };
      if (!create) fail('not_found');
      if (isProtected(parts.slice(0, index + 1))) fail('protected_path', parts.slice(0, index + 1).join('/'));
      fs.mkdirSync(current, { mode: 0o755 });
      created.push(current);
      stat = fs.lstatSync(current);
    }
    if (stat.isSymbolicLink()) fail('symlink_refused', parts.slice(0, index + 1).join('/'));
    if (!last && !stat.isDirectory()) fail('not_a_directory');
    if (last) return { abs: current, stat, created };
  }
  return { abs: root, stat: fs.lstatSync(root), created };
}

function openRegular(abs, flags = fs.constants.O_RDONLY) {
  let fd;
  try { fd = fs.openSync(abs, flags | fs.constants.O_NOFOLLOW); }
  catch (error) { fail(error.code === 'ELOOP' ? 'symlink_refused' : 'open_failed'); }
  const stat = fs.fstatSync(fd);
  if (!stat.isFile()) { fs.closeSync(fd); fail('not_a_regular_file'); }
  if (stat.nlink > 1) { fs.closeSync(fd); fail('hardlink_refused'); }
  return { fd, stat };
}

function readBytes(abs) {
  const { fd, stat } = openRegular(abs);
  try {
    if (stat.size > LIMITS.readFile) fail('file_too_large', stat.size);
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const n = fs.readSync(fd, buffer, offset, stat.size - offset, offset);
      if (n === 0) break;
      offset += n;
    }
    return { data: buffer.subarray(0, offset), mode: stat.mode & 0o777 };
  } finally { fs.closeSync(fd); }
}

// ---------- 秘密行（跟 App 的 HandsSecretLines 同一套規則） ----------
const PEM_BEGIN = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/;
const PEM_END = /-----END [A-Z0-9 ]*PRIVATE KEY-----/;
const KEY_LINE = /^[A-Za-z0-9+/]{60,}={0,2}$/;
const B64_TAIL = /^[A-Za-z0-9+/]{4,}={0,2}$/;
const BEARER_END = /\bBearer\s*$/i;
const FIRST_TOKEN = /^(\s*)[A-Za-z0-9._~+/=-]{8,}/;
export const MASKED_LINE = '[已遮蔽：私鑰／金鑰內容]';

function keyLine(trimmed) {
  return KEY_LINE.test(trimmed) && /[A-Z]/.test(trimmed) && /[a-z]/.test(trimmed) && /[0-9]/.test(trimmed);
}

/** 每一行要不要遮：'all'（整行）、'first'（開頭那個字）、null。要整個檔（或整段輸出）一起算，切頁之後才不會失去上下文。 */
export function secretLineMask(lines) {
  const mask = new Array(lines.length).fill(null);
  let inside = false;
  let body = false;   // 上一行是沒有 BEGIN 的金鑰內文（整行 base64）：下一行較短的 base64 是它的最後一行
  let bearer = false;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();
    let kind = null;
    let isBody = false;
    if (inside) {
      kind = 'all';
      if (PEM_END.test(line)) inside = false;
    } else if (PEM_BEGIN.test(line)) {
      kind = 'all';
      inside = !PEM_END.test(line.slice(line.search(PEM_BEGIN)));
    } else if (PEM_END.test(line)) {
      kind = 'all';
    } else if (keyLine(trimmed)) {
      kind = 'all';
      isBody = true;
    } else if (body && B64_TAIL.test(trimmed)) {
      kind = 'all';   // 內文的最後一行（較短）；之後就不算內文了
    } else if (bearer && FIRST_TOKEN.test(line)) {
      kind = 'first';
    }
    mask[index] = kind;
    body = isBody;
    bearer = BEARER_END.test(line);
  }
  return mask;
}

export function maskLine(line, kind) {
  if (kind === 'all') return MASKED_LINE;
  if (kind === 'first') return line.replace(FIRST_TOKEN, '$1[已遮蔽]');
  return line;
}

function readText(abs) {
  const { data, mode } = readBytes(abs);
  if (data.subarray(0, 8192).includes(0)) fail('binary_file');
  return { text: data.toString('utf8'), mode, hash: sha256(data) };
}

function writeAtomic(root, parts, content, { mode, limit = LIMITS.writeBytes } = {}) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
  if (bytes.length > limit) fail('content_too_large', bytes.length);
  const { abs, stat, created } = walk(root, parts, { create: true });
  let keepMode = mode ?? 0o644;
  if (stat) {
    if (!stat.isFile()) fail('not_a_regular_file');
    const opened = openRegular(abs);
    keepMode = opened.stat.mode & 0o777;
    fs.closeSync(opened.fd);
  }
  const temporary = path.join(path.dirname(abs), `.tatwo-hands-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, keepMode);
  try {
    let offset = 0;
    while (offset < bytes.length) offset += fs.writeSync(fd, bytes, offset, bytes.length - offset);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  try { fs.renameSync(temporary, abs); } catch { try { fs.unlinkSync(temporary); } catch {} fail('write_failed'); }
  return { created: !stat, bytes: bytes.length, sha256: sha256(bytes), createdDirectories: created };
}

/** 行號、總行數：以 \n 分行；檔尾的 \n 不算一行。 */
export function numberedSlice(text, offsetLine, limitLines) {
  const raw = text.split('\n');
  if (text.endsWith('\n')) raw.pop();
  const mask = secretLineMask(raw);   // 整個檔一起算，再切頁
  const lines = raw.map((line, index) => maskLine(line, mask[index]));
  const start = Math.max(1, Number.isInteger(offsetLine) ? offsetLine : 1);
  const count = Math.min(Math.max(1, Number.isInteger(limitLines) ? limitLines : 2000), 2000);
  const chosen = lines.slice(start - 1, start - 1 + count);
  let body = '';
  let shown = 0;
  for (const [index, line] of chosen.entries()) {
    const numbered = `${start + index}\t${line}\n`;
    if (Buffer.byteLength(body) + Buffer.byteLength(numbered) > LIMITS.returnBytes) break;
    body += numbered;
    shown += 1;
  }
  return { total_lines: lines.length, start_line: start, end_line: start - 1 + shown, lines: body, truncated: start - 1 + shown < lines.length };
}

function page(items, cursor, size) {
  let start = 0;
  if (typeof cursor === 'string' && /^c\d{1,9}$/.test(cursor)) start = Number(cursor.slice(1));
  const slice = items.slice(start, start + size);
  const next = start + slice.length;
  const result = { items: slice, complete: next >= items.length, total: items.length };
  if (next < items.length) result.cursor = `c${next}`;
  return result;
}

function opRead(request) {
  const root = checkRoot(request.root);
  const parts = splitPath(request.path, { forWrite: false });
  if (parts.length === 0) fail('path_required');
  if (parts[0].toLowerCase() === '.git') fail('protected_path', '.git');
  if (isSecretPath(parts)) fail('secret_file_refused');   // W183 R10 底線 A
  const { abs, stat } = walk(root, parts);
  if (!stat) fail('not_found');
  if (stat.isDirectory()) fail('is_a_directory');
  const { text, hash } = readText(abs);
  return { path: parts.join('/'), sha256: hash, ...numberedSlice(text, request.offset_line, request.limit_lines) };
}

function opList(request) {
  const root = checkRoot(request.root);
  const parts = splitPath(request.path, { forWrite: false });
  if (isSecretPath(parts)) fail('secret_file_refused');   // W183 R10 底線 A：金鑰類資料夾整個不列
  const { abs, stat } = walk(root, parts);
  if (!stat) fail('not_found');
  if (!stat.isDirectory()) fail('not_a_directory');
  let names;
  try { names = fs.readdirSync(abs); } catch { fail('not_readable'); }
  names = names.filter(name => !isSecretName(name));   // W183 R10 底線 A：翻頁之前就拿掉（總數也不算它們）
  names.sort();
  const entries = [];
  const rel = parts.join('/');
  for (const name of names.slice(0, LIMITS.listEntries)) {
    let info;
    try { info = fs.lstatSync(path.join(abs, name)); } catch { continue; }
    const type = info.isSymbolicLink() ? 'symlink' : info.isDirectory() ? 'dir' : info.isFile() ? 'file' : 'other';
    const entry = { path: rel ? `${rel}/${name}` : name, type };
    if (info.isFile()) entry.size = info.size;
    entries.push(entry);
  }
  const result = page(entries, request.cursor, LIMITS.listPage);
  if (names.length > LIMITS.listEntries) { result.complete = false; result.truncated_at_source = true; }
  return result;
}

function globToRegExp(glob) {
  let source = '';
  for (let index = 0; index < glob.length; index += 1) {
    const char = glob[index];
    if (char === '*') {
      if (glob[index + 1] === '*') { source += '.*'; index += 1; if (glob[index + 1] === '/') index += 1; }
      else source += '[^/]*';
    } else if (char === '?') source += '[^/]';
    else source += char.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${source}$`);
}

function opSearch(request) {
  const root = checkRoot(request.root);
  const parts = splitPath(request.path, { forWrite: false });
  if (isSecretPath(parts)) fail('secret_file_refused');   // W183 R10 底線 A
  const { abs, stat } = walk(root, parts);
  if (!stat) fail('not_found');
  const query = request.query;
  if (typeof query !== 'string' || query.length === 0 || query.length > 1000) fail('query_invalid');
  let find;
  if (request.regex) {
    let pattern;
    try { pattern = new RegExp(query, request.case_sensitive === false ? 'i' : ''); } catch { fail('regex_invalid'); }
    find = line => { const match = pattern.exec(line); return match ? match.index : -1; };
  } else if (request.case_sensitive === false) {
    const lowered = query.toLowerCase();
    find = line => line.toLowerCase().indexOf(lowered);
  } else {
    find = line => line.indexOf(query);
  }
  if (typeof request.glob === 'string' && (request.glob.length > 200 || /[\u0000-\u001f]/.test(request.glob))) fail('glob_invalid');
  const glob = typeof request.glob === 'string' && request.glob ? globToRegExp(request.glob) : null;
  const matches = [];
  let scanned = 0;
  let truncated = false;
  const visitFile = (file, rel) => {
    if (glob && !glob.test(rel) && !glob.test(path.basename(rel))) return;
    scanned += 1;
    let opened;
    try { opened = openRegular(file); } catch { return; }
    try {
      if (opened.stat.size > LIMITS.searchFileBytes) return;
      const buffer = Buffer.alloc(opened.stat.size);
      fs.readSync(opened.fd, buffer, 0, opened.stat.size, 0);
      if (buffer.subarray(0, 8192).includes(0)) return;
      const text = buffer.toString('utf8');
      const raw = text.split('\n');
      if (text.endsWith('\n')) raw.pop();
      const mask = secretLineMask(raw);
      const lines = raw.map((line, index) => maskLine(line, mask[index]));
      for (let index = 0; index < lines.length; index += 1) {
        if (mask[index] === 'all') continue;   // 被遮蔽的行不比對（不能拿搜尋當猜秘密的工具）
        const column = find(lines[index]);
        if (column < 0) continue;
        const clip = value => value.slice(0, LIMITS.lineChars);
        matches.push({
          location: `${rel}:${index + 1}:${column + 1}`, path: rel, line: index + 1, col: column + 1, text: clip(lines[index]),
          before: lines.slice(Math.max(0, index - 2), index).map((value, offset) => `${Math.max(0, index - 2) + offset + 1}: ${clip(value)}`),
          after: lines.slice(index + 1, index + 3).map((value, offset) => `${index + 2 + offset}: ${clip(value)}`),
        });
        if (matches.length >= LIMITS.searchMatches) { truncated = true; return; }
      }
    } finally { fs.closeSync(opened.fd); }
  };
  const visit = (dir, rel) => {
    let names;
    try { names = fs.readdirSync(dir).sort(); } catch { return; }
    for (const name of names) {
      if (truncated || scanned >= LIMITS.searchFiles) { truncated = true; return; }
      if (isSecretName(name)) continue;   // W183 R10 底線 A：金鑰類檔案、資料夾一律不看
      const child = path.join(dir, name);
      const childRel = rel ? `${rel}/${name}` : name;
      let info;
      try { info = fs.lstatSync(child); } catch { continue; }
      if (info.isSymbolicLink()) continue;
      if (info.isDirectory()) { if (!SKIP_DIRS.has(name)) visit(child, childRel); }
      else if (info.isFile()) visitFile(child, childRel);
    }
  };
  if (stat.isDirectory()) visit(abs, parts.join('/'));
  else visitFile(abs, parts.join('/'));
  const result = page(matches, request.cursor, LIMITS.searchPage);
  if (truncated) { result.complete = false; result.truncated_at_source = true; }
  result.files_scanned = scanned;
  return result;
}

function requireHash(value, actual, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) fail('expected_sha256_invalid', label);
  if (value !== actual) fail('file_changed', `${label}: sha256 is ${actual}; read the file again`);
}

function opWrite(request) {
  const root = checkRoot(request.root);
  const parts = splitPath(request.path, { forWrite: true });
  if (typeof request.content !== 'string') fail('content_invalid');
  const createOnly = request.create_only === true;
  if (createOnly === (typeof request.expected_sha256 === 'string')) fail('give exactly one of create_only or expected_sha256');
  const { abs, stat } = walk(root, parts, { allowMissing: true });
  if (createOnly) {
    if (stat) fail('file_exists', parts.join('/'));
  } else {
    if (!stat) fail('not_found', parts.join('/'));
    requireHash(request.expected_sha256, sha256(readBytes(abs).data), parts.join('/'));
  }
  const result = writeAtomic(root, parts, request.content);
  return { path: parts.join('/'), created: result.created, bytes: result.bytes, sha256: result.sha256 };
}

function countOccurrences(text, needle) {
  let count = 0;
  let index = text.indexOf(needle);
  while (index !== -1) { count += 1; index = text.indexOf(needle, index + needle.length); }
  return count;
}

function opEdit(request) {
  const root = checkRoot(request.root);
  const parts = splitPath(request.path, { forWrite: true });
  const { old_string: before, new_string: after } = request;
  if (typeof before !== 'string' || before.length === 0 || typeof after !== 'string') fail('edit_invalid');
  if (before === after) fail('edit_no_change');
  const { abs, stat } = walk(root, parts);
  if (!stat) fail('not_found');
  const { text, hash } = readText(abs);
  requireHash(request.expected_sha256, hash, parts.join('/'));
  const count = countOccurrences(text, before);
  if (count === 0) fail('old_string_not_found');
  if (count > 1 && request.replace_all !== true) fail('old_string_not_unique', count);
  const next = request.replace_all === true ? text.split(before).join(after) : text.replace(before, () => after);
  const result = writeAtomic(root, parts, next);
  return { path: parts.join('/'), bytes: result.bytes, sha256: result.sha256, replacements: request.replace_all === true ? count : 1 };
}

/** Codex 格式的 apply_patch（*** Begin Patch … *** End Patch）。 */
export function parsePatch(patch) {
  if (typeof patch !== 'string' || patch.length > LIMITS.writeBytes) fail('patch_invalid');
  const lines = patch.replace(/\r\n/g, '\n').split('\n');
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  if (lines[0]?.trim() !== '*** Begin Patch' || lines[lines.length - 1]?.trim() !== '*** End Patch') fail('patch_missing_markers');
  const operations = [];
  let index = 1;
  const end = lines.length - 1;
  while (index < end) {
    const line = lines[index];
    let match;
    if ((match = line.match(/^\*\*\* Add File: (.+)$/))) {
      const content = [];
      index += 1;
      while (index < end && !lines[index].startsWith('*** ')) {
        if (!lines[index].startsWith('+')) fail('patch_add_line_invalid', index + 1);
        content.push(lines[index].slice(1));
        index += 1;
      }
      operations.push({ type: 'add', path: match[1].trim(), content: content.join('\n') + (content.length ? '\n' : '') });
    } else if ((match = line.match(/^\*\*\* Delete File: (.+)$/))) {
      operations.push({ type: 'delete', path: match[1].trim() });
      index += 1;
    } else if ((match = line.match(/^\*\*\* Update File: (.+)$/))) {
      const operation = { type: 'update', path: match[1].trim(), moveTo: null, chunks: [] };
      index += 1;
      if (index < end && (match = lines[index].match(/^\*\*\* Move to: (.+)$/))) { operation.moveTo = match[1].trim(); index += 1; }
      let chunk = null;
      while (index < end && !/^\*\*\* (?:Add|Delete|Update) File: /.test(lines[index])) {
        const current = lines[index];
        if (current.startsWith('@@')) {
          chunk = { header: current.slice(2).trim(), old: [], new: [], eof: false };
          operation.chunks.push(chunk);
        } else if (current === '*** End of File') {
          if (chunk) chunk.eof = true;
        } else {
          if (!chunk) { chunk = { header: '', old: [], new: [], eof: false }; operation.chunks.push(chunk); }
          const marker = current[0];
          const body = current.slice(1);
          if (current === '') { chunk.old.push(''); chunk.new.push(''); }
          else if (marker === ' ') { chunk.old.push(body); chunk.new.push(body); }
          else if (marker === '-') chunk.old.push(body);
          else if (marker === '+') chunk.new.push(body);
          else fail('patch_hunk_line_invalid', index + 1);
        }
        index += 1;
      }
      if (operation.chunks.length === 0 && !operation.moveTo) fail('patch_update_empty', operation.path);
      operations.push(operation);
    } else if (line.trim() === '') {
      index += 1;
    } else {
      fail('patch_line_invalid', index + 1);
    }
  }
  if (operations.length === 0) fail('patch_empty');
  if (operations.length > 100) fail('patch_too_many_files');
  return operations;
}

function findSequence(haystack, needle, from, normalize) {
  if (needle.length === 0) return from;
  const target = needle.map(normalize);
  for (let start = from; start + needle.length <= haystack.length; start += 1) {
    let ok = true;
    for (let offset = 0; offset < needle.length; offset += 1) {
      if (normalize(haystack[start + offset]) !== target[offset]) { ok = false; break; }
    }
    if (ok) return start;
  }
  return -1;
}

export function applyChunks(text, chunks, file) {
  const endsWithNewline = text.endsWith('\n');
  const lines = (endsWithNewline ? text.slice(0, -1) : text).split('\n');
  let position = 0;
  chunks.forEach((chunk, number) => {
    if (chunk.header) {
      const at = lines.findIndex((line, lineIndex) => lineIndex >= position && line.trim() === chunk.header);
      if (at !== -1) position = at + 1;
    }
    let at = -1;
    if (chunk.old.length === 0) {
      at = chunk.eof ? lines.length : position;
    } else {
      for (const normalize of [value => value, value => value.trimEnd(), value => value.trim()]) {
        at = findSequence(lines, chunk.old, position, normalize);
        if (at !== -1) break;
        if (chunk.eof) {
          const tail = lines.length - chunk.old.length;
          if (tail >= 0 && findSequence(lines, chunk.old, tail, normalize) === tail) { at = tail; break; }
        }
      }
    }
    if (at === -1) fail('patch_context_not_found', `${file} #${number + 1}: ${(chunk.old[0] ?? '').slice(0, 120)}`);
    lines.splice(at, chunk.old.length, ...chunk.new);
    position = at + chunk.new.length;
  });
  return lines.join('\n') + (endsWithNewline || text === '' ? '\n' : '');
}

function opApplyPatch(request) {
  const root = checkRoot(request.root);
  const operations = parsePatch(request.patch);
  // 先在記憶體裡算好每個檔的結果，全部檢查過才寫；寫到一半失敗就照備份還原（全有或全無）。
  const planned = [];
  const touched = new Set();
  const claim = label => { if (touched.has(label)) fail('patch_touches_file_twice', label); touched.add(label); };
  for (const operation of operations) {
    const parts = splitPath(operation.path, { forWrite: true });
    claim(parts.join('/').toLowerCase());
    if (operation.type === 'add') {
      const { stat } = walk(root, parts, { create: false, allowMissing: true });
      if (stat) fail('file_exists', operation.path);
      planned.push({ kind: 'write', parts, content: operation.content, label: `A ${parts.join('/')}` });
    } else if (operation.type === 'delete') {
      const { abs, stat } = walk(root, parts);
      if (!stat) fail('not_found', operation.path);
      const backup = readBytes(abs);   // 一般檔、連結數 1 才刪；內容留著還原用
      planned.push({ kind: 'delete', abs, parts, backup, label: `D ${parts.join('/')}` });
    } else {
      const { abs, stat } = walk(root, parts);
      if (!stat) fail('not_found', operation.path);
      const backup = readBytes(abs);
      const { text } = readText(abs);
      const next = applyChunks(text, operation.chunks, operation.path);
      if (operation.moveTo) {
        const target = splitPath(operation.moveTo, { forWrite: true });
        claim(target.join('/').toLowerCase());
        const { stat: exists } = walk(root, target, { create: false, allowMissing: true });
        if (exists) fail('file_exists', operation.moveTo);
        planned.push({ kind: 'write', parts: target, content: next, label: `R ${parts.join('/')} -> ${target.join('/')}` });
        planned.push({ kind: 'delete', abs, parts, backup, label: null });
      } else {
        planned.push({ kind: 'write', parts, content: next, backup, label: `M ${parts.join('/')}` });
      }
    }
  }
  const done = [];
  const changed = [];
  try {
    for (const step of planned) {
      if (step.kind === 'write') {
        const result = writeAtomic(root, step.parts, step.content);
        done.push({ ...step, created: result.created, createdDirectories: result.createdDirectories });
      } else {
        fs.unlinkSync(step.abs);
        done.push(step);
      }
      if (step.label) changed.push(step.label);
    }
  } catch (error) {
    const unrestored = rollback(root, done);
    if (unrestored.length) {
      // 還原不完整：不能說「什麼都沒改」。備份放暫存區，App 會鎖住工作區並回報。
      const kept = keepBackups(done);
      fail('patch_partially_applied', `could not restore: ${unrestored.join(', ')}${kept ? `; backups kept in ${kept}` : ''}`);
    }
    if (error instanceof OpError) throw new OpError(error.code, `${error.detail ?? ''} (nothing was changed)`.trim());
    fail('patch_write_failed', 'nothing was changed');
  }
  return { changed };
}

/** 倒著還原：改過的寫回原內容與權限（上限跟讀檔一樣 8 MiB）、新建的刪掉、刪掉的放回去、新建的空資料夾拿掉；每一步都讀回來驗。
 *  回傳還原不了的路徑。 */
export function rollback(root, done) {
  const unrestored = [];
  for (const step of [...done].reverse()) {
    const rel = step.parts.join('/');
    try {
      if (step.kind === 'write' && step.created) {
        fs.unlinkSync(path.join(root, ...step.parts));
        for (const directory of [...(step.createdDirectories ?? [])].reverse()) { try { fs.rmdirSync(directory); } catch {} }
        let gone = false;
        try { fs.lstatSync(path.join(root, ...step.parts)); } catch (error) { gone = error.code === 'ENOENT'; }
        if (!gone) unrestored.push(rel);
      } else if (step.backup) {
        writeAtomic(root, step.parts, step.backup.data, { mode: step.backup.mode, limit: LIMITS.readFile });
        const again = readBytes(path.join(root, ...step.parts));
        if (sha256(again.data) !== sha256(step.backup.data)) unrestored.push(rel);
      }
    } catch {
      unrestored.push(rel);
    }
  }
  return unrestored;
}

/** 還原失敗時把備份寫到暫存區（沙盒裡的 TMPDIR），回傳資料夾；寫不了回 null。 */
function keepBackups(done) {
  const base = process.env.TMPDIR;
  if (!base) return null;
  try {
    const folder = fs.mkdtempSync(path.join(base, 'patch-backup-'));
    for (const step of done) {
      if (!step.backup) continue;
      const target = path.join(folder, ...step.parts);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, step.backup.data, { mode: 0o600 });
    }
    return path.basename(folder);
  } catch { return null; }
}

const OPERATIONS = { read: opRead, list: opList, search: opSearch, write: opWrite, edit: opEdit, apply_patch: opApplyPatch };

async function main() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > LIMITS.request) { process.stdout.write(JSON.stringify({ ok: false, error: 'request_too_large' })); return; }
    chunks.push(chunk);
  }
  let reply;
  try {
    const request = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const operation = OPERATIONS[request?.op];
    if (!operation) fail('unknown_op');
    reply = { ok: true, ...operation(request) };
  } catch (error) {
    reply = { ok: false, error: error instanceof OpError ? error.code : 'internal_error', detail: error instanceof OpError ? error.detail : undefined };
  }
  process.stdout.write(JSON.stringify(reply));
}

const invokedDirectly = (() => {
  try { return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); }
  catch { return false; }
})();
if (invokedDirectly) await main();
