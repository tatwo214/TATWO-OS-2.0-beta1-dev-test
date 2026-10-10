// One command in the same persistent synthetic plugin world; no HTTP is performed.
import fs from 'node:fs';
import { pluginsPage, records, MCP } from './w294-plugins-page.mjs';
import { queryAll } from '../w185-pod-fixture.mjs';
const [stateFile, payload] = process.argv.slice(2);
const world = pluginsPage(fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : records());
await world.pod.signIn();
const command = JSON.parse(payload);
const result = await world.pod.command({ url: MCP, ...command }, 12000, { press: false });
let data = result.data;
if (data.status === 'armed') {
  const armed = data;
  data = (await world.pod.command({ cmd: 'connectorPress', form: armed.form })).data;
  data.connector = armed.connector;
  const gesture = (await world.pod.command({ cmd: 'connectorGesture', url: MCP, name: armed.connector.name })).data;
  if (gesture.kind !== 'continue') throw new Error('Continue button missing');
  world.pod.userClick(queryAll(world.pod.body, 'button').find(b => b.textContent.startsWith('Continue to')));
}
fs.writeFileSync(stateFile, JSON.stringify(world.items));
process.stdout.write(JSON.stringify({ ...data, clicks: world.clicks }));
