#include "TatwoDownloadReservation.h"
#include <cassert>
#include <fcntl.h>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <cstring>

void PublishChecks();
void LongNameChecks();

int main() {
  assert(std::string(tatwo::DownloadErrnoName(EPERM)) == "EPERM");
  assert(std::string(tatwo::DownloadErrnoName(EACCES)) == "EACCES");
  assert(tatwo::DownloadCandidateName("Notchy.dmg", 1) == "Notchy (1).dmg");
  assert(tatwo::DownloadCandidateName("archive.tar.gz", 99) == "archive.tar (99).gz");
  assert(tatwo::DownloadCandidateName(".hidden", 1) == ".hidden (1)");
  assert(tatwo::DownloadCandidateName("plain", 2) == "plain (2)");
  assert(tatwo::DownloadCandidateName("sample.pdf", 0) == "sample.pdf");
  if (getenv("TATWO_W281F_RED_ONLY")) {
    const auto candidate = tatwo::DownloadCandidateName(std::string(248, 'a') + ".bin", 1);
    char pattern[] = "/tmp/tatwo-long-red-XXXXXX";
    const std::string root = mkdtemp(pattern), path = root + "/" + candidate;
    errno = 0; const int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
    printf("W281f RED inputBytes=252 candidateBytes=%zu fd=%d errno=%d %s\n", candidate.size(), fd, errno, tatwo::DownloadErrnoName(errno));
    assert(fd < 0 && errno == ENAMETOOLONG); rmdir(root.c_str()); return 0;
  }
  LongNameChecks();
  PublishChecks();
  char pattern[] = "/tmp/tatwo-reservation-test-XXXXXX";
  auto directory = mkdtemp(pattern);
  assert(directory);
  const std::string path = std::string(directory) + "/reserved.txt";
  const auto create = [&]() {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    assert(fd >= 0);
    struct stat info {};
    assert(fstat(fd, &info) == 0);
    close(fd);
    return info;
  };
  auto original = create();
  assert(tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(path.c_str(), F_OK) != 0);
  original = create();
  int fd = open(path.c_str(), O_WRONLY);
  assert(write(fd, "partial-user-data", 17) == 17); close(fd);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  struct stat partial {}; assert(stat(path.c_str(), &partial) == 0 && partial.st_size == 17);
  unlink(path.c_str());
  original = create();
  const auto retained = path + ".retained";
  assert(rename(path.c_str(), retained.c_str()) == 0);
  auto replacement = create();
  assert(replacement.st_ino != original.st_ino);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(path.c_str(), F_OK) == 0);
  unlink(path.c_str());
  assert(symlink(retained.c_str(), path.c_str()) == 0);
  assert(!tatwo::RemoveEmptyDownloadReservation(path.c_str(), original.st_dev, original.st_ino));
  assert(access(retained.c_str(), F_OK) == 0);
  assert(!tatwo::RemoveEmptyDownloadReservation(nullptr, original.st_dev, original.st_ino));
  unlink(path.c_str()); unlink(retained.c_str()); rmdir(directory);
  puts("PASS: empty owned reservation removed; partial data, replacement inode, and symlink preserved");
}

int unsupported(const char *, const char *, unsigned) { errno = ENOTSUP; return -1; }
int invalid(const char *, const char *, unsigned) { errno = EINVAL; return -1; }
int denied(const char *, const char *, unsigned) { errno = EPERM; return -1; }
int swapErr = EPERM;
int deniedSwap(const char *a, const char *b, unsigned flags) {
  if (flags == RENAME_SWAP) { errno = swapErr; return -1; }
  return renamex_np(a, b, flags);
}
int probeCalls = 0, failProbeAt = 0;
int probeMove(const char *a, const char *b, unsigned flags) {
  assert(std::string(a).substr(0, std::string(a).find_last_of('/')) == std::string(b).substr(0, std::string(b).find_last_of('/')));
  if (++probeCalls == failProbeAt) { errno = EPERM; return -1; }
  return renamex_np(a, b, flags);
}
int rollbackCalls = 0;
int failedRollback(const char *a, const char *b, unsigned flags) {
  if (++rollbackCalls == 2) { errno = EIO; return -1; }
  return renamex_np(a, b, flags);
}
int verifyCalls = 0;
int failedVerify(const char *a, const char *b, unsigned flags) {
  if (++verifyCalls == 2) {
    int fd = open(a, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    assert(fd >= 0); close(fd);
  }
  int result = renamex_np(a, b, flags);
  if (verifyCalls == 1) { struct stat info {}; assert(lstat(a, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == 0); assert(unlink(a) == 0); }
  return result;
}
void PublishChecks() {
  for (const std::string kind : {"swap", "user", "nonempty", "missing", "link", "dangling", "collisions", "exhausted", "unsupported", "invalid", "denied", "denied-swap", "swap-enotsup", "swap-einval", "swap-eio", "verify", "rollback", "rollback-exhausted"}) {
    char pattern[] = "/tmp/tatwo-publish-test-XXXXXX";
    const std::string root = mkdtemp(pattern), stage = root + "/downloads/.sample.UUID.tatwo-download", destination = root + "/downloads";
    assert(mkdir(destination.c_str(), 0700) == 0);
    const std::string name = "sample.pdf", source = stage, path = destination + "/" + name;
    auto create = [](const std::string &path, const std::string &bytes, mode_t mode) {
      int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode);
      assert(fd >= 0 && write(fd, bytes.data(), bytes.size()) == (ssize_t)bytes.size());
      struct stat info {}; assert(fstat(fd, &info) == 0); close(fd); return info;
    };
    auto readFile = [](const std::string &path) {
      char buffer[64] {}; int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
      assert(fd >= 0); auto count = read(fd, buffer, sizeof(buffer)); close(fd);
      assert(count >= 0); return std::string(buffer, count);
    };
    const auto downloaded = create(source, "%PDF-downloaded", 0644);
    if (kind == "swap") {
      const std::string probe = destination + "/.probe";
      for (failProbeAt = 0; failProbeAt <= 2; ++failProbeAt) {
        probeCalls = 0; const char *step = "";
        assert(tatwo::StagedDownloadSupportError(probe.c_str(), probeMove, &step) == (failProbeAt ? EPERM : 0));
        assert(std::string(step) == (failProbeAt == 1 ? "probe_swap" : failProbeAt == 2 ? "probe_excl" : ""));
        for (auto suffix : {"-a", "-b", "-excl"}) assert(access((probe + suffix).c_str(), F_OK) != 0);
      }
      for (auto conflict : {"-a", "-b", "-excl"}) {
        create(probe + conflict, "user probe", 0600);
        assert(tatwo::StagedDownloadSupportError(probe.c_str()) == EEXIST);
        assert(readFile(probe + conflict) == "user probe");
        for (auto suffix : {"-a", "-b", "-excl"})
          if (std::string(suffix) != conflict) assert(access((probe + suffix).c_str(), F_OK) != 0);
        unlink((probe + conflict).c_str());
      }
      assert(readFile(source) == "%PDF-downloaded");

    }
    const auto reserved = create(path, "", 0600);
    struct stat replacement {};
    const std::string retained = root + "/retained", victim = root + "/victim";
    if (kind == "nonempty") { int fd = open(path.c_str(), O_WRONLY); assert(write(fd, "user", 4) == 4); close(fd); replacement = reserved; }
    else if (kind != "swap" && kind != "unsupported" && kind != "invalid" && kind.rfind("denied", 0) != 0 && kind.rfind("swap-", 0) != 0 && kind != "verify") {
      assert(rename(path.c_str(), retained.c_str()) == 0);
      if (kind == "link" || kind == "dangling") {
        if (kind == "link") create(victim, "victim", 0644);
        assert(symlink(victim.c_str(), path.c_str()) == 0);
        assert(lstat(path.c_str(), &replacement) == 0);
      } else if (kind != "missing") replacement = create(path, "user", 0644);
    }
    int collisions = kind == "collisions" ? 3 : (kind == "exhausted" || kind == "rollback-exhausted") ? 20 : 0;
    for (int i = 1; i <= collisions; ++i) create(destination + "/sample (" + std::to_string(i) + ").pdf", "collision", 0644);
    rollbackCalls = 0; verifyCalls = 0;
    std::string published, recovered;
    swapErr = kind == "swap-enotsup" ? ENOTSUP : kind == "swap-einval" ? EINVAL : kind == "swap-eio" ? EIO : EPERM;
    auto renameFn = kind == "verify" ? failedVerify : kind == "unsupported" ? unsupported : kind == "invalid" ? invalid : kind == "denied" ? denied : (kind == "denied-swap" || kind.rfind("swap-", 0) == 0) ? deniedSwap : kind.rfind("rollback", 0) == 0 ? failedRollback : renamex_np;
    const auto outcome = tatwo::PublishStagedDownload(stage.c_str(), destination.c_str(), name.c_str(), reserved.st_dev, reserved.st_ino, published, renameFn, &recovered);
    const int result = outcome.error;
    if (kind == "unsupported" || kind == "invalid" || kind == "exhausted" || kind == "denied") {
      assert(result == (kind == "unsupported" ? ENOTSUP : kind == "invalid" ? EINVAL : kind == "denied" ? EPERM : EEXIST));
      assert(!outcome.complete && std::string(outcome.step) == "excl");
      assert(readFile(source) == "%PDF-downloaded");
      assert(readFile(path) == (kind == "exhausted" ? "user" : ""));
    } else if (kind.rfind("rollback", 0) == 0) {
      assert(!outcome.complete && std::string(outcome.step) == "swap_back");
      assert(result == EIO && published == name && readFile(path) == "%PDF-downloaded");
      struct stat info {}; assert(lstat(path.c_str(), &info) == 0 && info.st_ino == downloaded.st_ino);
      if (kind == "rollback") {
        assert(recovered == destination + "/sample (1).pdf" && readFile(recovered) == "user");
        assert(lstat(recovered.c_str(), &info) == 0 && info.st_ino == replacement.st_ino && info.st_dev == replacement.st_dev);
        assert(access(source.c_str(), F_OK) != 0);
        printf("S1 recovered=%s user inode=%llu bytes=user; private source absent; download=%s\n", recovered.c_str(), (unsigned long long)info.st_ino, path.c_str());
      } else {
        assert(recovered == source && readFile(source) == "user");
        assert(lstat(source.c_str(), &info) == 0 && info.st_ino == replacement.st_ino);
      }
    } else {
      assert(outcome.complete);
      assert(result == (kind == "verify" ? ENOENT : (kind == "denied-swap" || kind.rfind("swap-", 0) == 0) ? swapErr : 0));
      if (kind == "missing") assert(std::string(outcome.step).empty());
      if (kind == "verify") assert(std::string(outcome.step) == "verify");
      if (kind == "denied-swap" || kind.rfind("swap-", 0) == 0) assert(std::string(outcome.step) == "swap");
      assert(published == ((kind == "swap" || kind == "missing") ? name : kind == "collisions" ? "sample (4).pdf" : "sample (1).pdf"));
      const auto final = destination + "/" + published;
      struct stat info {}; assert(lstat(final.c_str(), &info) == 0 && info.st_ino == downloaded.st_ino && (info.st_mode & 0777) == (downloaded.st_mode & 0777));
      assert(readFile(final) == "%PDF-downloaded");
      if (replacement.st_ino) { assert(lstat(path.c_str(), &info) == 0 && info.st_ino == replacement.st_ino); }
      if (kind == "user" || kind == "nonempty" || kind == "collisions") assert(readFile(path) == "user");
      if (kind == "link") assert(readFile(victim) == "victim");
      if (kind == "dangling") assert(access(victim.c_str(), F_OK) != 0);
      if (kind == "swap") assert(access(source.c_str(), F_OK) != 0);
    }
    // All removals below are this isolated fixture's explicitly created files.
    unlink(path.c_str()); unlink(source.c_str()); unlink(retained.c_str()); unlink(victim.c_str());
    for (int i = 1; i <= 21; ++i) unlink((destination + "/sample (" + std::to_string(i) + ").pdf").c_str());
    assert(rmdir(destination.c_str()) == 0 && rmdir(root.c_str()) == 0);
    printf("PASS: staged publication %s\n", kind.c_str());
  }
}

void LongNameChecks() {
  const std::string uuid = "12345678-1234-1234-1234-123456789abc-";
  const auto repeat = [](const std::string &unit, int count) { std::string s; while (count--) s += unit; return s; };
  for (const auto &name : {std::string("short.bin"), std::string(246, 'a') + ".bin", std::string(248, 'a') + ".bin", std::string(251, 'a') + ".bin", repeat("報", 83) + ".bin", repeat("👨‍👩‍👧‍👦", 10) + ".bin", repeat("e\xcc\x81", 83) + ".bin", repeat("🇹🇼", 31) + ".bin"}) {
    for (int i : {0, 1, 20, 99}) {
      const auto candidate = tatwo::DownloadCandidateName(name, i);
      assert(candidate.size() <= 255 && candidate.substr(candidate.size() - 4) == ".bin");
      const auto suffix = i ? " (" + std::to_string(i) + ")" : "";
      const auto stem = candidate.substr(0, candidate.size() - 4 - suffix.size());
      auto text = CFStringCreateWithBytes(nullptr, (const UInt8 *)candidate.data(), candidate.size(), kCFStringEncodingUTF8, false);
      assert(text); CFRelease(text);
      assert(name.compare(0, stem.size(), stem) == 0);
      if (name.find("👨") == 0) assert(stem.size() % std::string("👨‍👩‍👧‍👦").size() == 0);
      if (name.find("e\xcc\x81") == 0) assert(stem.size() % 3 == 0);
      if (name.find("🇹🇼") == 0) assert(stem.size() % 8 == 0);
      const auto fallback = tatwo::DownloadCandidateName(name, 0, uuid);
      assert(fallback.size() <= 255 && fallback.find(uuid) == 0 && fallback.substr(fallback.size() - 4) == ".bin");
      text = CFStringCreateWithBytes(nullptr, (const UInt8 *)fallback.data(), fallback.size(), kCFStringEncodingUTF8, false);
      assert(text); CFRelease(text);
      const auto fallbackStem = fallback.substr(uuid.size(), fallback.size() - uuid.size() - 4);
      if (name.find("👨") == 0) assert(fallbackStem.size() % 25 == 0);
      if (name.find("e\xcc\x81") == 0) assert(fallbackStem.size() % 3 == 0);
      if (name.find("🇹🇼") == 0) assert(fallbackStem.size() % 8 == 0);
      printf("W281f helper inputBytes=%zu index=%d candidateBytes=%zu uuidBytes=%zu\n", name.size(), i, candidate.size(), fallback.size());
    }
    const auto prefix = tatwo::DownloadUTF8Prefix(name, 100);
    assert(prefix.size() <= 100 && name.compare(0, prefix.size(), prefix) == 0);
    if (name.find("👨") == 0) assert(prefix.size() == 100);
    if (name.find("e\xcc\x81") == 0) assert(prefix.size() == 99);
    if (name.find("🇹🇼") == 0) assert(prefix.size() == 96);
  }
  assert(tatwo::DownloadCandidateName(std::string(255, 'a'), 1) == std::string(251, 'a') + " (1)");
  assert(tatwo::DownloadCandidateName("." + std::string(254, 'a'), 1) == "." + std::string(250, 'a') + " (1)");
  assert(tatwo::DownloadCandidateName(std::string(248, 'a') + ".tar.gz", 1) == std::string(248, 'a') + " (1).gz");
  // An extension consuming the entire budget cannot be kept together with a number.
  assert(tatwo::DownloadCandidateName("a." + std::string(253, 'b'), 1).empty());
  assert(tatwo::DownloadUTF8Prefix("e\xcc\x81", 2).empty());
  assert(tatwo::DownloadUTF8Prefix("👨‍👩‍👧‍👦", 24).empty());
  for (const auto &kind : {"excl", "rollback", "extension"}) {
    char pattern[] = "/tmp/tatwo-long-publish-XXXXXX";
    const std::string root = mkdtemp(pattern), stage = root + "/.stage", name = std::string(kind) == "extension" ? "a." + std::string(253, 'b') : std::string(251, 'a') + ".bin", path = root + "/" + name;
    auto create = [](const std::string &path, const char *bytes) { int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0644); assert(fd >= 0); assert(write(fd, bytes, strlen(bytes)) == (ssize_t)strlen(bytes)); struct stat info {}; assert(fstat(fd, &info) == 0); close(fd); return info; };
    create(stage, "download"); const auto user = create(path, "user"); rollbackCalls = 0;
    std::string published, recovered;
    const auto result = tatwo::PublishStagedDownload(stage.c_str(), root.c_str(), name.c_str(), 0, 0, published, std::string(kind) == "rollback" ? failedRollback : deniedSwap, &recovered);
    if (std::string(kind) == "extension") {
      assert(!result.complete && result.error == ENAMETOOLONG && std::string(result.step) == "excl");
      struct stat info {}; assert(lstat(root.c_str(), &info) == 0 && S_ISDIR(info.st_mode));
      assert(lstat(path.c_str(), &info) == 0 && info.st_ino == user.st_ino);
      assert(access(stage.c_str(), F_OK) == 0);
      char bytes[5] {}; int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
      assert(fd >= 0 && read(fd, bytes, 4) == 4); close(fd); assert(std::string(bytes) == "user");
      unlink(path.c_str()); unlink(stage.c_str()); assert(rmdir(root.c_str()) == 0);
      puts("W281f helper impossible extension retains user inode and directory; ENAMETOOLONG"); continue;
    }
    assert(result.complete == (std::string(kind) == "excl"));
    const auto numbered = tatwo::DownloadCandidateName(name, 1); struct stat info {};
    const auto preserved = std::string(kind) == "rollback" ? recovered : path;
    assert(lstat(preserved.c_str(), &info) == 0 && info.st_ino == user.st_ino);
    assert((std::string(kind) == "rollback" ? recovered : root + "/" + published) == root + "/" + numbered);
    assert(numbered.size() == 255);
    unlink(path.c_str()); unlink(stage.c_str()); unlink((root + "/" + numbered).c_str()); assert(rmdir(root.c_str()) == 0);
    printf("W281f helper long %s numberedBytes=%zu user inode preserved\n", kind, numbered.size());
  }
}
