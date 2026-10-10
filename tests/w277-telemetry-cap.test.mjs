import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const bridge = fs.readFileSync(fileURLToPath(new URL(
  '../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', import.meta.url)), 'utf8');
const limit = 64 * 1024;
const scratch = testScratch('w277-telemetry-');
const source = bridge.slice(bridge.indexOf('constexpr NSUInteger kCEFEmbeddingTelemetryMaximumLineLength'),
  bridge.indexOf('void RecordHostBlocklistRequest('));
assert.match(source, /MaximumFileBytes = 16 \* 1024 \* 1024;/);
const fixture = path.join(scratch, 'probe.mm');
const binary = path.join(scratch, 'probe');
fs.writeFileSync(fixture, `
#import <AppKit/AppKit.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
NSString *g_embedding_telemetry_path;
static int opens, stats, rotations;
static int queue_key;
static bool short_writes, interrupted, fail_rotation;
int ProbeOpen(const char *path, int flags, mode_t mode) {
  assert(dispatch_get_specific(&queue_key));
  ++opens;
  return open(path, flags, mode);
}
int ProbeStat(int fd, struct stat *status) { ++stats; return fstat(fd, status); }
int ProbeRename(const char *from, const char *to) {
  assert(dispatch_get_specific(&queue_key));
  if (fail_rotation) { errno = EACCES; return -1; }
  ++rotations;
  return rename(from, to);
}
ssize_t ProbeWrite(int fd, const void *bytes, size_t length) {
  assert(dispatch_get_specific(&queue_key));
  if (short_writes && !interrupted) { interrupted = true; errno = EINTR; return -1; }
  return write(fd, bytes, short_writes ? MIN(length, 17UL) : length);
}
#define open ProbeOpen
#define fstat ProbeStat
#define rename ProbeRename
#define write ProbeWrite
${source.replace('MaximumFileBytes = 16 * 1024 * 1024;', 'MaximumFileBytes = 64 * 1024;')}
int main(int argc, char **argv) {
  @autoreleasepool {
    assert(argc == 4);
    NSString *mode = @(argv[2]);
    int count = atoi(argv[3]);
    short_writes = [mode isEqualToString:@"short"];
    fail_rotation = [mode isEqualToString:@"fail-rotation"];
    dispatch_queue_set_specific(CEFEmbeddingTelemetryQueue(), &queue_key, &queue_key, nullptr);
    ConfigureCEFEmbeddingTelemetry(@(argv[1]));
    NSString *token = [@"é" stringByPaddingToLength:900 withString:@"é" startingAtIndex:0];
    auto append = ^(size_t i) {
      NSString *line = [NSString stringWithFormat:
          @"phase=message_pump_summary sequence=%06zu token=%@", i, token];
      if ([mode isEqualToString:@"concurrent"] && i % 2 == 0)
        AppendCEFEmbeddingTelemetryLineSynchronously(line);
      else AppendCEFEmbeddingTelemetryLine(line);
    };
    if ([mode isEqualToString:@"concurrent"])
      dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), append);
    else for (int i = 0; i < count; ++i) append(i);
    dispatch_sync(CEFEmbeddingTelemetryQueue(), ^{});
    printf("opens=%d stats=%d rotations=%d\\n", opens, stats, rotations);
  }
}
`);

let compiled = false;
function run(dir, mode = 'sequential', count = 0) {
  if (!compiled) {
    const result = spawnSync('xcrun', ['clang++', '-std=c++17', '-fobjc-arc', '-fblocks',
      '-framework', 'AppKit', fixture, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    compiled = true;
  }
  const result = spawnSync(binary, [path.join(dir, 'cef.log'), mode, String(count)], {
    encoding: 'utf8', timeout: 30_000,
  });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  const [, opens, stats, rotations] = result.stdout.match(/opens=(\d+) stats=(\d+) rotations=(\d+)/);
  assert.equal(Number(opens), Number(stats), 'only one size read per open');
  assert.equal(Number(opens), Number(rotations) + 1, 'no open/stat on each line');
  return Number(rotations);
}
const filename = 'cef-embedding-telemetry.log';
function directory() { return fs.mkdtempSync(path.join(scratch, 'case-')); }
function line(i) {
  return `phase=message_pump_summary sequence=${String(i).padStart(6, '0')} token=${'é'.repeat(900)}\n`;
}
function read(dir, suffix = '') { return fs.readFileSync(path.join(dir, filename + suffix), 'utf8'); }
function checkFiles(dir) {
  assert.deepEqual(fs.readdirSync(dir).sort(), [filename, filename + '.1']);
  for (const suffix of ['', '.1']) {
    const content = read(dir, suffix);
    assert.ok(Buffer.byteLength(content) < limit, 'each retained file is below the limit');
    assert.ok(content.endsWith('\n'), 'no partial final line');
    for (const record of content.trimEnd().split('\n')) {
      const sequence = record.match(/^phase=message_pump_summary sequence=(\d{6}) token=/)?.[1];
      assert.ok(sequence, 'complete telemetry fields');
      assert.equal(record + '\n', line(Number(sequence)), 'exact UTF-8 line content');
    }
  }
}

test('64 KB rotation uses byte counts, overwrites only .1, and preserves complete lines', () => {
  const dir = directory();
  fs.writeFileSync(path.join(dir, filename), line(999999));
  fs.writeFileSync(path.join(dir, filename + '.1'), 'obsolete backup\n');
  let current = line(999999), previous, rotations = 0;
  for (let i = 0; i < 150; ++i) {
    const payload = line(i);
    if (Buffer.byteLength(current + payload) >= limit) {
      previous = current; current = ''; ++rotations;
    }
    current += payload;
  }
  assert.ok(rotations > 2);
  assert.equal(run(dir, 'sequential', 150), rotations);
  assert.equal(read(dir), current);
  assert.equal(read(dir, '.1'), previous);
  checkFiles(dir);
});

test('startup rotates an oversized existing file before any new line; other logs stay intact', () => {
  const dir = directory();
  const oversized = line(999999).repeat(40);
  assert.ok(Buffer.byteLength(oversized) > limit);
  fs.writeFileSync(path.join(dir, filename), oversized);
  fs.writeFileSync(path.join(dir, filename + '.1'), 'obsolete backup\n');
  fs.writeFileSync(path.join(dir, 'cef.log'), 'CEF untouched\n');
  fs.writeFileSync(path.join(dir, 'other.log'), 'other untouched\n');
  assert.equal(run(dir), 1);
  assert.equal(read(dir), '');
  assert.equal(read(dir, '.1'), oversized);
  assert.equal(fs.readFileSync(path.join(dir, 'cef.log'), 'utf8'), 'CEF untouched\n');
  assert.equal(fs.readFileSync(path.join(dir, 'other.log'), 'utf8'), 'other untouched\n');
  assert.deepEqual(fs.readdirSync(dir).sort(), ['cef.log', filename, filename + '.1', 'other.log'].sort());
});

test('concurrent synchronous and asynchronous calls open and rotate only on the serial queue', () => {
  const dir = directory();
  assert.ok(run(dir, 'concurrent', 150) > 2);
  checkFiles(dir);
  const retained = (read(dir, '.1') + read(dir)).trimEnd().split('\n');
  assert.equal(new Set(retained).size, retained.length, 'no duplicate retained records');
});

test('short writes and EINTR preserve complete lines and count actual bytes', () => {
  const dir = directory();
  assert.equal(run(dir, 'short', 40), 1);
  checkFiles(dir);
  assert.equal(read(dir, '.1') + read(dir), Array.from({ length: 40 }, (_, i) => line(i)).join(''));
});

test('a failed rename preserves both files and does not append beyond the cap', () => {
  const dir = directory();
  const content = line(999999).repeat(35);
  assert.ok(Buffer.byteLength(content) < limit);
  assert.ok(Buffer.byteLength(content + line(0)) >= limit);
  fs.writeFileSync(path.join(dir, filename), content);
  fs.writeFileSync(path.join(dir, filename + '.1'), 'previous backup\n');
  assert.equal(run(dir, 'fail-rotation', 2), 0);
  assert.equal(read(dir), content);
  assert.equal(read(dir, '.1'), 'previous backup\n');
});
