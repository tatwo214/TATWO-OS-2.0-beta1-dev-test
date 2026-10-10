#import <Foundation/Foundation.h>
#include "TatwoDownloadReservation.h"
#include <cassert>
#include <cstring>
#include <vector>

enum Fault { none, createDenied, createInterrupted, writeFailed, writeInterrupted,
  writeZero, closeFailed, renameDenied, renameInterrupted, cleanupInterrupted };
static Fault fault = none;
static int writes = 0, cleanups = 0;
static NSString *root;
static void ownPath(const char *path) {
  assert([@(path).stringByDeletingLastPathComponent isEqualToString:root]);
}
static int planOpen(const char *path, int flags, mode_t mode) {
  ownPath(path); assert(strstr(path, "/.tatwo-plan-"));
  assert((flags & (O_CREAT | O_EXCL | O_NOFOLLOW)) == (O_CREAT | O_EXCL | O_NOFOLLOW));
  if (fault == createDenied || fault == createInterrupted) {
    errno = fault == createDenied ? EACCES : EINTR; return -1;
  }
  return open(path, flags, mode);
}
static ssize_t planWrite(int fd, const void *bytes, size_t length) {
  if (++writes > 1) {
    if (fault == writeFailed || fault == cleanupInterrupted) { errno = ENOSPC; return -1; }
    if (fault == writeInterrupted) { errno = EINTR; return -1; }
    if (fault == writeZero) return 0;
  }
  return write(fd, bytes, std::min(length, size_t(3)));
}
static int planClose(int fd) {
  int result = close(fd);
  if (fault == closeFailed) { errno = EIO; return -1; }
  return result;
}
static int planMove(const char *from, const char *to, unsigned flags) {
  ownPath(from); ownPath(to); assert(flags == RENAME_EXCL);
  if (fault == renameDenied || fault == renameInterrupted) {
    errno = fault == renameDenied ? EPERM : EINTR; return -1;
  }
  return renamex_np(from, to, flags);
}
static int planUnlink(const char *path) {
  ownPath(path); assert(strstr(path, "/.tatwo-plan-"));
  if (++cleanups == 1 && fault == cleanupInterrupted) { errno = EINTR; return -1; }
  return unlink(path);
}
#define open planOpen
#define write planWrite
#define close planClose
#define renamex_np planMove
#define unlink planUnlink
#include "TatwoPlanExport.mm"
#undef open
#undef write
#undef close
#undef renamex_np
#undef unlink

static NSArray *files() { return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]; }
static NSData *payload() { return [@"# PLAN\n施工內容 👨‍👩‍👧‍👦 é\n" dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *exportName(NSString *name, NSError **error) {
  writes = 0; cleanups = 0;
  return [TatwoPlanExport writeData:payload() directory:root name:name error:error];
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    assert(argc == 2);
    root = [@(argv[1]) stringByAppendingPathComponent:@"downloads"];
    assert([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil]);
    NSString *original = [root stringByAppendingPathComponent:@"PLAN.md"];
    assert([@"user-owned" writeToFile:original atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    struct stat before {}, after {}; assert(lstat(original.fileSystemRepresentation, &before) == 0);
    for (NSString *expected in @[@"PLAN (1).md", @"PLAN (2).md"]) {
      assert([exportName(@"PLAN.md", nullptr) isEqualToString:expected]);
      assert([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:expected]] isEqualToData:payload()]);
    }
    assert(lstat(original.fileSystemRepresentation, &after) == 0 && before.st_ino == after.st_ino);
    assert([[NSString stringWithContentsOfFile:original encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"user-owned"]);
    for (NSString *unit in @[@"a", @"中", @"👨‍👩‍👧‍👦", @"é", @"🇹🇼"]) {
      NSMutableString *name = [NSMutableString string];
      while ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 255) [name appendString:unit];
      [name appendString:@".md"];
      for (int i = 0; i <= 2; ++i) {
        NSString *actual = exportName(name, nullptr);
        auto candidate = tatwo::DownloadCandidateName(name.UTF8String, i);
        assert(actual && [actual isEqualToString:@(candidate.c_str())]);
        assert([actual lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 255);
        assert([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:actual]] isEqualToData:payload()]);
      }
    }
    NSArray *saved = files();
    for (Fault failing : {createDenied, createInterrupted, writeFailed, writeInterrupted, writeZero, closeFailed, renameDenied, renameInterrupted, cleanupInterrupted}) {
      fault = failing; NSError *error = nil;
      assert(!exportName(@"PLAN.md", &error));
      const int code = failing == createDenied ? EACCES : failing == writeFailed || failing == cleanupInterrupted ? ENOSPC :
          failing == writeZero || failing == closeFailed ? EIO : failing == renameDenied ? EPERM : EINTR;
      assert(error.code == code);
      assert([error.localizedDescription containsString:@(tatwo::DownloadErrnoName(code))]);
      assert([error.localizedDescription containsString:@"計畫匯出失敗"]);
      assert([files() isEqualToArray:saved]); // No final or hidden partial file.
    }
    fault = none;
    for (int i = 3; i <= 99; ++i) {
      auto candidate = tatwo::DownloadCandidateName("PLAN.md", i);
      assert([@"user-owned" writeToFile:[root stringByAppendingPathComponent:@(candidate.c_str())] atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    }
    saved = files(); NSError *error = nil;
    assert(!exportName(@"PLAN.md", &error) && error.code == EEXIST);
    assert([files() isEqualToArray:saved]);
    NSString *extension = [@"a." stringByPaddingToLength:257 withString:@"x" startingAtIndex:0];
    assert(!exportName(extension, &error) && error.code == ENAMETOOLONG);
    assert(!exportName(@"../outside.md", &error) && error.code == EINVAL);
    assert([files() isEqualToArray:saved]);
    puts("PASS: W283 native collisions / UTF-8 / short writes / I/O failure cleanup");
  }
}
