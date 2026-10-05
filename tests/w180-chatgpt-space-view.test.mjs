import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const space = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTSpace.swift', import.meta.url), 'utf8');

// W180 A2（09-27 實機）：看過長對話再開新對話（含專案裡的新對話），對話區一片空白，
// 送出後的提問與錯誤都落在看不到的地方，看起來像「送出失敗」。
test('conversation scroll view is rebuilt per conversation / new chat', () => {
  assert.match(space, /@Published private\(set\) var viewEpoch = 0/);
  const conversation = space.split('private var conversation: some View {')[1].split('private var emptyState')[0];
  assert.match(conversation, /\}\n\s*\.id\(model\.viewEpoch\)\n\s*\.onChange\(of: model\.messages\.last\?\.text\)/);
  for (const fn of ['func newChat(with gpt: TapFolder? = nil) {', 'func select(_ id: String) {']) {
    const body = space.split(fn)[1].split('\n    }\n')[0];
    assert.match(body, /viewEpoch \+= 1/, fn);
  }
});

test('failure line sits outside the scroll area, above the composer', () => {
  const conversation = space.split('private var conversation: some View {')[1].split('private var emptyState')[0];
  assert.doesNotMatch(conversation, /model\.failure/);
  const native = space.split('private var nativeContent: some View {')[1].split('.onDrop(')[0];
  assert.match(native, /conversation\n[\s\S]*if let failure = model\.composerFailure \{[\s\S]*accessibilityIdentifier\("chatgpt\.failure"\)[\s\S]*\n\s*composer/);
});

// W180 A2（09-27 .012 實機）：專案裡生圖成功，但串流結束時圖還在產生，畫面先寫「沒有收到回覆」。
test('async replies (image generation) are awaited before reporting no reply', () => {
  const consume = space.split('private func consume(')[1].split('\n    }\n\n')[0];
  const wait = consume.indexOf('awaitingAsyncReplyID = conversationID');
  const fail = consume.indexOf('沒有收到 ChatGPT 的回覆');
  assert.ok(wait > 0 && fail > wait, 'waits before the no-reply failure');
  assert.match(consume, /reloaded = await waitForSavedReply\(conversationID, timeout: 180\)/);
  const helper = space.split('private func waitForSavedReply(')[1].split('\n    }\n')[0];
  assert.match(helper, /Task\.sleep\(for: \.seconds\(4\)\)/);
  assert.match(helper, /saved\.last\?\.role == \.assistant/);
  assert.match(helper, /remember\(conversationID, saved\)/);
  assert.match(helper, /if selectedID == conversationID, !isSending \{ messages = saved \}/);
  assert.match(space, /ChatGPT 還在產生（例如圖片），好了會自動顯示/);
});

// W180 A2（.013 實機）：專案裡只有大圖的對話，網址與輸入框都到了，訊息慢很久才畫出來 → 以前判成「沒開到」。
test('follow-up in a conversation proceeds once the URL and composer are right, even if messages render late', () => {
  const tap = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTTap.swift', import.meta.url), 'utf8');
  const anchor = 'async function openConversation(conversationID, command = null) {';
  const at = tap.indexOf(anchor);
  assert.ok(at >= 0, 'missing production openConversation declaration');
  const end = tap.indexOf('\n      }\n', at);
  assert.ok(end > at, 'missing production openConversation end');
  const open = tap.slice(at, end);
  assert.match(open, /const cancelled = \(\) => !!\(command && command\.cancelled\);\s*if \(cancelled\(\)\) return false;/);
  assert.match(open, /const urlReady = \(\) => \(conversationID \? location\.pathname\.endsWith\(target\) : location\.pathname === '\/'\) && composer\(\);/);
  assert.match(open, /const arrived = \(\) => urlReady\(\) && \(!conversationID \|\| document\.querySelector\('\[data-message-author-role\]'\)\)/);
  assert.match(open, /let ready = arrived\(\) \|\| \(await routeTo\(target, arrived, command\)\);/);
  assert.match(open, /if \(!ready && conversationID && urlReady\(\)\) \{\s*ready = !!\(await waitFor\(\(\) => cancelled\(\) \|\| arrived\(\), 8000\)\);\s*if \(cancelled\(\)\) return false;\s*if \(!ready && urlReady\(\)\) \{ ready = true;/);
  // 網址不對時照舊不送。
  assert.match(open, /if \(!ready\) return false;/);
  assert.match(open, /await sleep\(conversationID \? 700 : 250\);\s*return !cancelled\(\);/);
});
