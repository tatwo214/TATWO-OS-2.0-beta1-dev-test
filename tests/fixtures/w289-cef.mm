// Native fixture links the actual room bridge object. DNS never leaves this process.
#import "TatwoCEFBridge.h"
#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include <netdb.h>
#include <sys/resource.h>
#include <fstream>
#include <atomic>

extern "C" int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
  // The bridge's private-network check uses this resolver. Chromium independently
  // maps these exact names to loopback via host-resolver-rules. Every other name fails.
  if (!node || (strcmp(node, "x.com") && strcmp(node, "twitter.com") && strcmp(node, "fixture.invalid"))) return EAI_NONAME;
  auto item = (addrinfo *)calloc(1, sizeof(addrinfo));
  auto address = (sockaddr_in *)calloc(1, sizeof(sockaddr_in));
  address->sin_len = sizeof(*address); address->sin_family = AF_INET;
  address->sin_addr.s_addr = htonl(INADDR_LOOPBACK); address->sin_port = htons(service ? atoi(service) : 80);
  item->ai_family = AF_INET; item->ai_socktype = SOCK_STREAM; item->ai_addrlen = sizeof(*address);
  item->ai_addr = (sockaddr *)address; *result = item; return 0;
}
extern "C" void freeaddrinfo(addrinfo *item) { while(item) { auto next=item->ai_next; free(item->ai_addr); free(item); item=next; } }
class Audit final : public CefDevToolsMessageObserver {
 public:
  std::atomic<int> replies{0};
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int, bool, const void *, size_t) override { replies++; }
  IMPLEMENT_REFCOUNTING(Audit);
};
static double CPU() { rusage r{}; getrusage(RUSAGE_SELF, &r); return r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6; }
int main(int argc, char **argv) {
 @autoreleasepool {
  [TatwoCEFApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSString *root = @(getenv("TATWO_STAGING_ROOT")), *port = @(getenv("W289_PORT"));
  NSString *bundle = NSBundle.mainBundle.bundlePath;
  NSString *helper = [bundle stringByAppendingPathComponent:@"Contents/Frameworks/W258 Helper.app/Contents/MacOS/W258 Helper"];
  NSError *error = nil;
  if (![TatwoCEFRuntime initializeWithRootCachePath:[root stringByAppendingPathComponent:@"cache"] helperExecutablePath:helper
      logFilePath:[root stringByAppendingPathComponent:@"cef.log"] bundledDenyListPath:[bundle stringByAppendingPathComponent:@"Contents/Resources/BrowserBlocklists/browser-host-deny-list.json"] error:&error]) {
    NSLog(@"fixture startup failed %@", error); return 2;
  }
  NSString *host = NSProcessInfo.processInfo.environment[@"W289_HOST"] ?: @"x.com";
  TatwoCEFBrowserView *view = [[TatwoCEFBrowserView alloc] initWithFrame:NSMakeRect(0,0,1000,700) persistentProfile:nil
      initialURL:[NSString stringWithFormat:@"http://%@:%@/timeline",host,port] actor:TatwoCEFBrowserActorHuman error:&error];
  view.adBlock = NO;
  view.onPrivateNetworkRequested = ^(NSString *, TatwoCEFDecisionHandler answer) { answer(YES); };
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,1000,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO; window.contentView = view; [window orderFrontRegardless];
  double start = NSDate.timeIntervalSinceReferenceDate, cpu = CPU(); int seconds = atoi(getenv("W289_SECONDS") ?: "135");
  CefRefPtr<Audit> audit = new Audit; CefRefPtr<CefRegistration> registration;
  while (NSDate.timeIntervalSinceReferenceDate - start < seconds) { @autoreleasepool {
    if (!registration) { auto browser = CefBrowserHost::GetBrowserByIdentifier(1); if (browser) registration = browser->GetHost()->AddDevToolsMessageObserver(audit); }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
  }}
  double duration = NSDate.timeIntervalSinceReferenceDate-start;
  NSDictionary *stats = @{@"cpuSeconds": @(CPU()-cpu), @"wallSeconds": @(duration), @"cpuPercent": @((CPU()-cpu)*100/duration), @"devToolsReplies": @(audit->replies.load())};
  [[NSJSONSerialization dataWithJSONObject:stats options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[root stringByAppendingPathComponent:@"host-stats.json"] atomically:YES];
  registration = nullptr;
  __block BOOL closed = NO; [view closeBrowserWithCompletion:^{closed=YES;}]; [window close];
  while (!closed && NSDate.timeIntervalSinceReferenceDate-start < seconds+15) { @autoreleasepool { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; }}
  [TatwoCEFRuntime shutdown]; return closed ? 0 : 3;
 }
}
