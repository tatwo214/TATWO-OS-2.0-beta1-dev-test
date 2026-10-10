#pragma once

#ifdef __cplusplus
#include <CoreFoundation/CoreFoundation.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <cerrno>
#include <string>

namespace tatwo {
// A cancelled transfer may leave the empty O_EXCL reservation behind. Only
// remove that same empty regular file; replacements and partial data survive.
inline bool RemoveEmptyDownloadReservation(const char *path, dev_t device, ino_t inode) {
  struct stat info {};
  return path && inode && lstat(path, &info) == 0 && S_ISREG(info.st_mode) &&
      info.st_dev == device && info.st_ino == inode && info.st_size == 0 && unlink(path) == 0;
}
inline std::string DownloadUTF8Prefix(const std::string &name, size_t limit) {
  if (name.size() <= limit) return name;
  auto text = CFStringCreateWithBytes(nullptr, (const UInt8 *)name.data(), name.size(), kCFStringEncodingUTF8, false);
  if (!text) return {};
  size_t bytes = 0;
  for (CFIndex i = 0; i < CFStringGetLength(text);) {
    auto range = CFStringGetRangeOfComposedCharactersAtIndex(text, i); CFIndex count = 0;
    CFStringGetBytes(text, range, kCFStringEncodingUTF8, 0, false, nullptr, 0, &count);
    if (bytes + count > limit) break;
    bytes += count; i += range.length;
  }
  CFRelease(text); return name.substr(0, bytes);
}
inline std::string DownloadCandidateName(const std::string &name, int index, const std::string &prefix = {}) {
  auto dot = name.find_last_of('.');
  if (dot == std::string::npos || dot == 0) dot = name.size();
  const auto tail = (index ? " (" + std::to_string(index) + ")" : "") + name.substr(dot);
  if (prefix.size() + tail.size() > 255) return {}; // No room for an intact extension.
  return prefix + DownloadUTF8Prefix(name.substr(0, dot), 255 - prefix.size() - tail.size()) + tail;
}
// Probe only two exclusively created hidden files in the destination directory.
inline int StagedDownloadSupportError(const char *probe, decltype(&renamex_np) move = renamex_np,
    const char **failedStep = nullptr) {
  const std::string first = std::string(probe) + "-a", second = std::string(probe) + "-b", other = std::string(probe) + "-excl";
  struct stat ai {}, bi {}; bool moved = false; int error = 0; const char *step = "create_probe_a";
  auto create = [&](const std::string &path, struct stat &info) {
    int fd = open(path.c_str(), O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, 0600);
    if (fd < 0) return errno;
    int result = fstat(fd, &info) == 0 ? 0 : errno; close(fd); return result;
  };
  error = create(first, ai);
  if (!error) { step = "create_probe_b"; error = create(second, bi); }
  if (!error) { step = "probe_swap"; if (move(first.c_str(), second.c_str(), RENAME_SWAP)) error = errno; }
  if (!error) { step = "probe_excl"; if (move(first.c_str(), other.c_str(), RENAME_EXCL)) error = errno; else moved = true; }
  for (const auto &path : {first, second, other}) {
    if ((path == first && (!ai.st_ino || moved)) || (path == second && !bi.st_ino) || (path == other && !moved)) continue;
    struct stat info {};
    if (lstat(path.c_str(), &info)) { if (!error) { error = errno; step = "verify_probe"; } continue; }
    if (S_ISREG(info.st_mode) && info.st_size == 0 &&
        ((ai.st_ino && info.st_dev == ai.st_dev && info.st_ino == ai.st_ino) || (bi.st_ino && info.st_dev == bi.st_dev && info.st_ino == bi.st_ino))) {
      if (unlink(path.c_str()) && !error) { error = errno; step = "cleanup_probe"; }
    } else if (!error) { error = ESTALE; step = "verify_probe"; }
  }
  if (failedStep) *failedStep = error ? step : "";
  return error;
}
// Numbered publication can complete while retaining the failed SWAP diagnostic.
struct DownloadPublishResult { int error; const char *step; bool complete; };
inline const char *DownloadErrnoName(int error) {
#define DL_ERR(e) case e: return #e
  switch (error) {
    DL_ERR(EPERM); DL_ERR(EACCES); DL_ERR(ENOENT); DL_ERR(EEXIST); DL_ERR(EIO);
    DL_ERR(ENOTSUP); DL_ERR(EINVAL); DL_ERR(ENOTDIR); DL_ERR(ELOOP); DL_ERR(EXDEV);
    DL_ERR(ENOSPC); DL_ERR(EDQUOT); DL_ERR(EROFS); DL_ERR(ESTALE); DL_ERR(ENAMETOOLONG);
    DL_ERR(EBADF); DL_ERR(ENOTEMPTY); DL_ERR(EINTR); DL_ERR(EMFILE); DL_ERR(ENFILE); DL_ERR(ENOMEM);
    default: return "UNKNOWN";
  }
#undef DL_ERR
}
inline DownloadPublishResult PublishStagedDownload(const char *staging, const char *downloads, const char *name,
    dev_t device, ino_t inode, std::string &published, decltype(&renamex_np) move = renamex_np, std::string *recovered = nullptr) {
  published.clear(); if (recovered) recovered->clear();
  const std::string target = std::string(downloads) + "/" + name;
  auto finish = [](int error, const char *step, bool complete = false) { return DownloadPublishResult{error, step, complete}; };
  int swapError = 0; const char *step = "swap";
  if (move(staging, target.c_str(), RENAME_SWAP) == 0) {
    published = name;
    struct stat info {};
    int verified = lstat(staging, &info);
    if (verified == 0 && S_ISREG(info.st_mode) &&
        info.st_dev == device && info.st_ino == inode && inode && info.st_size == 0)
      return unlink(staging) == 0 ? finish(0, "", true) : finish(errno, "verify");
    if (verified < 0) { swapError = errno; step = "verify"; }
    if (move(staging, target.c_str(), RENAME_SWAP) != 0) {
      const int error = errno;
      if (recovered) *recovered = staging;
      for (int i = 0; i <= 20; ++i) {
        const auto candidate = DownloadCandidateName(name, i);
        if (candidate.empty()) break;
        if (move(staging, (std::string(downloads) + "/" + candidate).c_str(), RENAME_EXCL) == 0) { if (recovered) *recovered = std::string(downloads) + "/" + candidate; break; }
        if (errno != EEXIST) break;
      }
      return finish(error, "swap_back");
    }
    published.clear();
  } else swapError = errno;
  for (int i = 0; i <= 20; ++i) {
    const auto candidate = DownloadCandidateName(name, i);
    if (candidate.empty()) return finish(ENAMETOOLONG, "excl");
    if (move(staging, (std::string(downloads) + "/" + candidate).c_str(), RENAME_EXCL) == 0) { published = candidate; return i == 0 ? finish(0, "", true) : finish(swapError, step, true); }
    if (errno != EEXIST) return finish(errno, "excl");
  }
  return finish(EEXIST, "excl");
}
}  // namespace tatwo
#endif
