import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('W269 web window uses Browser geometry, footer and a single shared toggle; DM and native keep their routes', () => {
  const page = read('Chat/ChatPage.swift');
  for (const reserve of ['leadingReserve', 'trailingReserve']) assert.match(page, new RegExp(`usesBrowserTopChrome\\) \\? 0 : layoutPolicy\\.${reserve}`));
  assert.match(page, /sidebarContentGap = usesBrowserTopChrome \? WorkspaceSidebarMetrics.browserContentGap/);
  const panels = read('Chat/ChatPage+Panels.swift');
  const web = panels.slice(panels.indexOf('if ChatGPTWebSpace.isEnabled'), panels.indexOf('ChatGPTSpaceMainPane'));
  assert.equal((page.match(/BrowserSidebarControls\(/g) || []).length, 1);
  assert.match(page, /usesBrowserTopChrome && model.mode == \.chatgpt && webSpaceChromeReveal.revealed/);
  assert.match(page, /BrowserSidebarControls\(store: browserWorkSpaceStore\)/);
  assert.doesNotMatch(web, /EmbeddedBrowserToolbar|browserActionsButton|auxiliaryBrowserControls/);
  assert.match(read('Chat/ChatPage+Sidebar.swift'), /ChatGPTSpaceSidebarList[^}]+\}\s*workspaceSidebarFooter/);
  assert.doesNotMatch(read('TAP/ChatGPTWebSpace.swift'), /BrowserSidebarControls|BrowserChromeRevealHost|ignoresSafeArea/);
  assert.match(page, /model.mode == \.chatgpt && !ChatGPTWebSpace.isEnabled \{[\s\S]*ChatGPTTopBarControls/);
  assert.match(read('TAP/W269GPTChromeAcceptance.swift'), /rig\.click[\s\S]*store\.focusMode[\s\S]*rig\.click[\s\S]*store\.sidebarPinned/);
});
