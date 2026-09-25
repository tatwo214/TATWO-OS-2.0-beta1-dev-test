#!/usr/bin/env node
// TATWO2_BROWSERTEST node 直連 probe；不經 MCP stdio。
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

// W178：App 登記完這支探針才建立檔案；之前連線會被當成外部程式。
if (process.env.TATWO2_PROBE_READY_FILE) {
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(process.env.TATWO2_PROBE_READY_FILE) && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  if (!fs.existsSync(process.env.TATWO2_PROBE_READY_FILE)) {
    console.log('BROWSERTEST FAIL probe_not_registered');
    process.exit(1);
  }
}
const socketPath = process.env.TATWO2_BROWSER_SOCKET || path.join(os.homedir(), 'Library', 'Application Support', 'tatwo2', 'live', 'browser-v2.sock');
let id = 1;
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let data = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.end(JSON.stringify({ id: id++, method, params }) + '\n'));
    socket.on('data', chunk => { data += chunk; });
    socket.on('error', reject);
    socket.on('close', () => {
      try {
        const reply = JSON.parse(data.trim());
        if (!reply.ok) reject(new Error(reply.error)); else resolve(reply.result);
      } catch (error) { reject(error); }
    });
  });
}
try {
  console.log('BROWSERTEST open=' + JSON.stringify(await call('browser_open', { url: 'https://example.com' })));
  const read = await call('browser_read', { maxChars: 8000 });
  console.log('BROWSERTEST read=' + JSON.stringify(read));
  if (!String(read.text || '').includes('Example Domain')) process.exitCode = 1;
  else console.log('BROWSERTEST PASS Example Domain');
} catch (error) {
  console.error('BROWSERTEST FAIL ' + String(error?.stack || error));
  process.exitCode = 1;
}
