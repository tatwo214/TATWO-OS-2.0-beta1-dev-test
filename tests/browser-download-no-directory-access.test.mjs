import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
const read = p => process.env.W281E_SOURCE_REV
  ? execFileSync('git', ['show', `${process.env.W281E_SOURCE_REV}:${p}`], {encoding: 'utf8'})
  : fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const helper = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoDownloadReservation.h');
const download = bridge.slice(bridge.indexOf('  struct HumanDownload {'), bridge.indexOf('#pragma mark - W57d\n', bridge.indexOf('  struct HumanDownload {'))) +
  bridge.slice(bridge.indexOf('  bool CanDownload('), bridge.indexOf('  bool OnBeforeBrowse(', bridge.indexOf('  bool CanDownload(')));
test('download operations never read a directory or use directory descriptors', () => {
  for (const [label, source] of [['download', download], ['helper', helper]]) {
    assert.doesNotMatch(source, /\b(?:O_DIRECTORY|mkdirat|openat|renameatx_np|fstatat|unlinkat|opendir|contentsOfDirectory|NSItemReplacementDirectory|rmdir|mkdir|rename|renameat|enumerator|URLForDirectory|createDirectory|getattrlist)\b/, label);
    assert.doesNotMatch(source, /\b(?:lstat|unlink|open)\((?:root|downloads|directory)(?:\.|,)/, label);
    for (const call of source.matchAll(/\bopen\(([^;]+?)\);/g)) {
      for (const flag of ['O_CREAT', 'O_EXCL', 'O_NOFOLLOW']) assert.ok(call[1].includes(flag), `${label}: ${call[0]} lacks ${flag}`);
    }
  }
  assert.match(helper, /decltype\(&renamex_np\)/);
  assert.match(download, /callback->Continue\(ToCefString\(entry\.staging \?: path\), false\)/);
  assert.match(download, /\.tatwo-download/);
  assert.doesNotMatch(download, /open\((?:entry\.)?staging\.fileSystemRepresentation/);
});
test('Swift download UI uses individual files; history stays in Application Support', () => {
  const store = read('App/Sources/Tatwo2/Browser/BrowserDownloadStore.swift');
  assert.doesNotMatch(store, /contentsOfDirectory|enumerator|NSItemReplacementDirectory|appropriateForURL|opendir|getattrlist/);
  assert.match(store, /Library\/Application Support\/tatwo2\/browser-downloads.json/);
  assert.match(store, /activateFileViewerSelecting\(\[url\]\)/);
  assert.match(store, /next\.setUserInfoObject\(item\.fileURL, forKey: \.fileURLKey\)/);
});
