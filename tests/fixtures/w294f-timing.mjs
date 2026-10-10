// Use the unchanged W208 page and default command deadline; observe late results separately.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { makePage, h, MCP } from '../w185-pod-fixture.mjs';

const NAME = 'TATWO（Synthetic Device）';
const source = readFileSync(new URL('../w208-tap-stress.test.mjs', import.meta.url), 'utf8');
const factory = source.slice(source.indexOf('function connectorPage('), source.indexOf("\ntest('unfinished"));
const connectorPage = new Function('makePage', 'h', 'MCP', factory + '\nreturn connectorPage;')(makePage, h, MCP);
const foreign = { id: 'asdk_app_original', name: NAME, url: 'https://other.example.com/mcp', authorized: false };

for (const cmd of ['connectorDelete', 'connectorReconnect']) {
  const { pod, clicks } = connectorPage([{ ...foreign }]);
  await pod.signIn();
  await pod.command({ cmd: 'connectorScan', url: MCP });
  const routes = [], navigate = pod.pageState.onNavigate;
  const start = performance.now();
  pod.pageState.onNavigate = path => { routes.push({ path, ms: Math.round(performance.now() - start) }); navigate(path); };
  const count = pod.reports.length;
  let timeoutMS = null;
  try {
    await pod.command({ cmd, url: MCP, connectorID: foreign.id, name: NAME, keeping: 'active-connector' });
  } catch (error) {
    assert.match(error.message, /timed out connector/);
    timeoutMS = Math.round(performance.now() - start);
  }
  let result;
  while (!(result = pod.reports.slice(count).find(r => r.type === 'result'))) {
    assert.ok(performance.now() - start < 30000, 'diagnostic result observation deadline');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  const elapsedMS = Math.round(performance.now() - start);
  assert.notEqual(result.data?.deleted, true);
  assert.notEqual(result.data?.status, 'pressed');
  assert.deepEqual(clicks.delete, []);
  assert.deepEqual(clicks.connect, []);
  console.log(JSON.stringify({ cmd, elapsedMS, timeoutMS, routes, result: result.data }));
}
