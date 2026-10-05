import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Only browser-diagnostics and browser-stress use this fixture. Compile the real
// media status/report implementation; omit the UI and never inspect a real CEF profile.
export function protectedMediaFixture() {
  const source = readFileSync(new URL('../../App/Sources/Tatwo2/Browser/BrowserProtectedMedia.swift', import.meta.url), 'utf8');
  const start = source.indexOf('enum BrowserProtectedMedia {');
  const end = source.indexOf('    /// 重新啟動：', start);
  const hardware = source.indexOf('private extension ProcessInfo {', end);
  const ui = source.indexOf('/// 設定 › 瀏覽器', hardware);
  assert.ok(start >= 0 && end > start && hardware > end && ui > hardware, 'media extraction boundaries');
  return `import AppKit
enum TatwoCEFProfileLocationResolver {
    static func rootCacheURL() -> URL? { nil }
}
${source.slice(start, end)}
}
${source.slice(hardware, ui)}
`;
}

export const protectedMediaChecks = `
let launch = Date(timeIntervalSince1970: 100)
precondition(BrowserProtectedMedia.installedVersion(rootCache: nil) == nil)
precondition(BrowserProtectedMedia.status(enabled: false, launched: true, cdm: ("1", launch), launchDate: launch) == .off)
precondition(BrowserProtectedMedia.status(enabled: true, launched: false, cdm: ("1", launch), launchDate: launch) == .needsRestart)
precondition(BrowserProtectedMedia.status(enabled: true, launched: true, cdm: nil, launchDate: launch) == .downloading)
precondition(BrowserProtectedMedia.status(enabled: true, launched: true, cdm: ("1", launch.addingTimeInterval(1)), launchDate: launch) == .downloadedNeedsRestart("1"))
precondition(BrowserProtectedMedia.status(enabled: true, launched: true, cdm: ("1", launch), launchDate: launch) == .ready("1"))
precondition(BrowserDiagnosticsReport().text.contains(BrowserProtectedMedia.diagnosticsLine))
precondition(BrowserProtectedMedia.diagnosticsLine.contains("DRM 影片（Widevine）"))
`;
