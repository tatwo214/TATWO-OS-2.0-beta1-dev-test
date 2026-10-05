import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('M17 DM and settings use the same system permission name', () => {
  const name = '裝置控制和資料取用（舊稱輔助使用）';
  for (const path of ['DM/GlobalDMDeskViews.swift', 'DM/GlobalDMPhoneBox.swift', 'New/ComputerUseSettingsView.swift', 'New/DisplaySettingsView.swift', 'Facade/PluginsBuiltinSource.swift']) {
    assert.ok(read(path).includes(name), `${path} uses the unified permission name`);
  }
});
