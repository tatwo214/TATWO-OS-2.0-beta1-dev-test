import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = name => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');

test('DM reuses web Space with glass segments and keeps native opt-out', () => {
  assert.match(read('DM/GlobalDMView.swift'), /if ChatGPTWebSpace.isEnabled, store.chatGPTAvailable, let pod = store.chatGPT.tap.webPod \{\s*ChatGPTWebSpacePane\(tap: store.chatGPT.tap, pod: pod, showsTabs: true\)\s*\} else \{\s*GlobalDMChatGPTPane/);
  const pane = read('TAP/ChatGPTWebSpace.swift');
  assert.match(pane, /Text\(value \? "Dots" : "ChatGPT"\)/);
  assert.match(pane, /\.buttonStyle\(\.plain\)\.chatGlassChip\(\)/);
  assert.match(pane, /if dots == value \{[\s\S]*\.strokeBorder\(ChatGlassChipModifier.chipForeground.opacity\(0.55\), lineWidth: 1.5\)/);
  assert.match(pane, /\.accessibilityAddTraits\(dots == value \? \.isSelected : \[\]\)/);
  assert.match(pane, /\.task\(id: dots\)/);
  assert.doesNotMatch(pane, /\.loadURLString|\.borderedProminent|Color\.blue|\.tint\(\.blue\)/);
  const phone = read('DM/GlobalDMPhoneBox.swift');
  assert.match(phone, /if look.showsChat \|\| webChatGPTTent/);
  assert.match(phone, /!ChatGPTWebSpace.isEnabled && store.target == \.chatGPT/);
  assert.match(read('DM/GlobalDMPanelController.swift'), /guard !ChatGPTWebSpace.isEnabled else \{ return event \}/);
});

test('both human pages keep the Pod context, documents and profile lifetime', () => {
  const pod = read('TAP/TapWebPod.swift');
  assert.match(pod, /func openSpacePage\(\)[\s\S]*if let spacePage \{ return spacePage \}/);
  assert.match(pod, /func openDotsSpacePage\(\)[\s\S]*if let dotsSpacePage \{ return dotsSpacePage \}/);
  assert.match(pod, /var url = ChatGPTDotsState.url/);
  assert.match(pod, /sharingContextWith: browser,[\s\S]*initialURL: url.absoluteString, actor: \.human/);
  assert.match(pod, /let pages = \[browser\] \+ \[spacePage, dotsSpacePage\].compactMap \{ \$0 \}/);
  assert.match(pod, /if pending == 0, let lease \{ TatwoCEFProfileLeaseRegistry.shared.release\(lease\) \}/);
});

test('first visible surface owns both pages; waiting panes never steal views', () => {
  assert.match(read('TAP/TapWebPod.swift'), /guard spaceHost == nil \|\| spaceHost == id else \{ return false \}/);
  const pane = read('TAP/ChatGPTWebSpace.swift');
  assert.match(pane, /occupied = !pod.acquireSpaceHost\(hostID\)/);
  assert.match(pane, /guard next.superview == nil else \{ return \}/);
  assert.match(pane, /\.onDisappear \{\s*waiting = false; pod.releaseSpaceHost\(hostID\)/);
  assert.match(pane, /guard page.superview == nil else \{ return \}/);
  assert.doesNotMatch(pane, /page.removeFromSuperview/);
});

test('Space retries on Pod notifications, including CEF readiness and page detachment, with a single deadline', () => {
  const pane = read('TAP/ChatGPTWebSpace.swift');
  const pod = read('TAP/TapWebPod.swift');
  assert.doesNotMatch(pane, /\bwhile\b|milliseconds\(50\)/);
  assert.equal(pane.match(/Task\.sleep/g)?.length, 1);
  assert.match(pane, /Task\.sleep\(for: \.seconds\(60\)\)/);
  assert.match(pane, /\.task\(id: dots\) \{\s*guard !Task.isCancelled else \{ return \}/);
  assert.match(pane, /\.onReceive\(NotificationCenter.default.publisher\(for: TapWebPod.spaceChanged, object: pod\).receive\(on: RunLoop.main\)\) \{ _ in mountPage\(\) \}/);
  assert.match(pane, /guard waiting, failure == nil, pod.browser\?\.canShareRequestContext == true else \{ return \}/);
  assert.match(pod, /releaseSpaceHost[^\n]*spaceHost = nil; spaceDidChange\(\)/);
  assert.doesNotMatch(pod, /page\.stateHandler/);
  assert.match(pane, /ChatGPTWebSpaceSurface\(page: page, pod: pod\)/);
  assert.match(pane, /func makeCoordinator\(\) -> TapWebPod \{ pod \}/);
  assert.match(pane, /if view.browserView != nil \{ view.detachBorrowedBrowser\(\); pod.spaceDidChange\(\) \}/);
  assert.match(pane, /dismantleNSView[^\n]*coordinator: TapWebPod\) \{\s*view.detachBorrowedBrowser\(\)\s*coordinator.spaceDidChange\(\)/);
  assert.match(pod, /view.stateHandler[\s\S]*canShareRequestContext == true[^\n]*spaceDidChange\(\)/);
});

test('CEF regression proves release-before-dismantle and bounds the single-notification handoff', () => {
  const fixture = read('DM/W265DMChatGPTAcceptance.swift');
  assert.match(fixture, /notifications\.append\(attached\)/);
  assert.match(fixture, /notifications\.contains\(true\) && chat\.superview === oldContainer/);
  assert.match(fixture, /check\(chat\.superview === oldContainer && oldContainer != nil/);
  assert.ok(fixture.indexOf('rig.window.contentView = nil') < fixture.indexOf('let detachedAt'));
  assert.match(fixture, /rig\.host\.layoutSubtreeIfNeeded\(\)\s*let deadline = detachedAt \+ 1/);
  assert.match(fixture, /oldContainer as\? TatwoCEFContainerView\)\?\.browserView == nil && chat\.superview !== oldContainer/);
  assert.match(fixture, /chat\.window === main\.window && reverseMS < 1000/);
  assert.match(fixture, /notifications\.count - notificationCount == 1 && notifications\.last == false/);
  assert.match(fixture, /in: main\.host\)\.count == 1/);
  for (const name of ['reverse-1-before', 'reverse-2-released-retained', 'reverse-3-mounted', 'dm-to-main-mounted', 'main-to-dm-mounted']) {
    assert.ok(fixture.includes('screenshot("' + name + '"'), name);
  }
});
