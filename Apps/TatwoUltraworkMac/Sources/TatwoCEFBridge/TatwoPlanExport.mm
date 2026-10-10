#import "TatwoPlanExport.h"
#include "TatwoDownloadReservation.h"
#include <cstring>

@implementation TatwoPlanExport
+ (NSString *)writeData:(NSData *)data directory:(NSString *)directory
    name:(NSString *)name error:(NSError **)error {
  int failure = 0; NSString *published = nil; const char *step = "create";
  if (!name.length || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) failure = EINVAL;
  NSString *staging = [directory stringByAppendingPathComponent:
      [@".tatwo-plan-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  int fd = failure ? -1 : open(staging.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0 && !failure) failure = errno;
  const bool created = fd >= 0;
  if (created) {
    step = "write"; size_t offset = 0;
    while (offset < data.length) {
      ssize_t count = write(fd, (const char *)data.bytes + offset, data.length - offset);
      if (count <= 0) { failure = count < 0 ? errno : EIO; break; }
      offset += count;
    }
    if (close(fd) && !failure) { failure = errno; step = "close"; }
  }
  if (!failure) {
    step = "excl";
    for (int i = 0; i <= 99; ++i) {
      const auto candidate = tatwo::DownloadCandidateName(name.UTF8String, i);
      if (candidate.empty()) { failure = ENAMETOOLONG; break; }
      NSString *filename = [NSString stringWithUTF8String:candidate.c_str()];
      NSString *target = [directory stringByAppendingPathComponent:filename];
      if (renamex_np(staging.fileSystemRepresentation, target.fileSystemRepresentation, RENAME_EXCL) == 0) { published = filename; break; }
      failure = errno;
      if (failure != EEXIST) break;
      if (i < 99) failure = 0;
    }
  }
  if (published) return published;
  int cleanup = 0;
  if (created) { do { cleanup = unlink(staging.fileSystemRepresentation); } while (cleanup && errno == EINTR); }
  if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:@"計畫匯出失敗（%s／%s）：%@。請檢查下載資料夾的權限與可用空間後重試。%@",
          step, tatwo::DownloadErrnoName(failure), @(strerror(failure)),
          cleanup ? [@"暫存檔無法移除：" stringByAppendingString:staging] : @""]}];
  return nil;
}
@end
