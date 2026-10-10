import { installedPage, connector, MCP } from './w304b-installed-sidebar.mjs';
import { settingsPage, installedRows } from './w325-pluginsettings-dom.mjs';
const mode = process.argv[2];
const world = mode === 'w325' ? settingsPage({ items: installedRows().slice(0, 1) })
  : installedPage(mode === 'existing' ? [connector()] : [], { missingInstalled: mode === 'missing' });
await world.pod.signIn();
process.stdout.write(JSON.stringify((await world.pod.command({ cmd: 'connectorScan', url: MCP })).data));
