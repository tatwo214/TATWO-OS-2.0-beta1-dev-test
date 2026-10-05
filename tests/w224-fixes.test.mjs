import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const swift = name => fs.readFileSync(new URL(`../App/Sources/Tatwo2/${name}`, import.meta.url), 'utf8');

test('W224-1 targeted Login entries expand and scroll; ordinary Login stays collapsed', () => {
  const settings = swift('Shell/ChatPageSettings.swift');
  const login = swift('New/EngineLoginCard.swift');
  const environment = swift('New/EnvironmentLoginPage.swift');
  assert.match(environment, /enum EnvironmentLoginTarget/);
  for (const target of ['update', 'backup', 'github', 'cloudflare']) assert.match(environment, new RegExp(`\\b${target}\\b`));
  assert.match(environment, /userInfo: \["environmentTarget": rawValue\]/);
  assert.match(settings, /environmentTarget = target == \.github/);
  assert.match(settings, /environmentTarget: environmentTarget/);
  assert.match(login, /@State private var environmentExpanded = false/);
  assert.match(login, /ScrollViewReader/);
  assert.match(login, /environmentExpanded = true/);
  assert.match(login, /scrollTo\(target\.rawValue, anchor: \.top\)/);
  assert.match(login, /target == \.backup \? "github" : target\.rawValue/);
  assert.match(login, /accessibilityIdentifier\("login\.environment\.backup"\)/);
  assert.match(swift('Shell/SetupGuide.swift'), /EnvironmentLoginTarget\.backup\.open\(\)/);
});

test('W224-5 every HandsBuild copy member has a production consumer, not just retired UI selftests', () => {
  const source = swift('Facade/HandsBuildModel.swift');
  const begin = source.indexOf('enum HandsBuildCopy {');
  const end = source.indexOf('// MARK: - 1.');
  const declarations = [...source.slice(begin, end).matchAll(/static (?:let|var|func) (\w+)/g)].map(m => m[1]);
  const root = new URL('../App/Sources/Tatwo2/', import.meta.url);
  const production = fs.readdirSync(root, { recursive: true }).filter(name =>
    name.endsWith('.swift') && !name.endsWith('Acceptance.swift') && name !== 'Facade/HandsBuildModel.swift'
  ).map(name => fs.readFileSync(new URL(name, root), 'utf8')).join('\n') + source.slice(0, begin) + source.slice(end);
  const code = production.replace(/\/\/[^\n]*/g, '');
  const unused = declarations.filter(name => !code.includes(`HandsBuildCopy.${name}`));
  assert.deepEqual(unused, [], 'Copy kept alive only by removed screens/selftests must be deleted');
});

test('W224-4 Coder uses the same memory content, actions and retryable detailed errors', () => {
  const coder = swift('New/ChatSystemNoteRow.swift');
  const shared = swift('Memory/TatwoMemoryUsageRow.swift');
  assert.match(coder, /TatwoMemoryUsageRow\(note: note, rowWidth: rowWidth, revealsMemory: revealsMemory\)/);
  assert.doesNotMatch(coder, /markIrrelevant|memoryStatus|Task\.detached/);
  assert.match(shared, /if expanded \|\| revealsMemory/);
  assert.match(shared, /error as\? LocalizedError/);
  assert.match(shared, /marked\[item\.id\] = nil/);
});

test('W224-3 cached project catalogs refresh silently and only first-load failures show errors', () => {
  const source = swift('TAP/ChatGPTSpace.swift');
  const body = source.slice(source.indexOf('    func retryProjects()'), source.indexOf('    /// App 開好後'));
  assert.match(body, /if projects\.isEmpty && projectsLoadState != \.loaded \{ projectsLoadState = \.loading \}/);
  assert.match(body, /if projects\.isEmpty && projectsLoadState != \.loaded \{ projectsLoadState = \.failed/);
  assert.match(body, /if projects != loaded \{ projects = loaded \}/);
  assert.match(body, /guard !Task\.isCancelled else \{ return \}/);
});

test('W224-2 unrelated or undecodable events are silent; diagnostics append and trim periodically', () => {
  const source = swift('Display/DisplayKeyTap.swift');
  assert.doesNotMatch(source, /decode_failed/);
  assert.match(source, /FileHandle\(forWritingTo: url\)/);
  assert.match(source, /seekToEnd\(\)/);
  assert.match(source, /logWrites % 50 == 0/);
  assert.match(source, /suffix\(200\)/);
});
