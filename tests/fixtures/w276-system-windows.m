// External observer: WindowServer metadata; no pixels or Screen Recording access.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
    NSMutableArray *apps = [NSMutableArray array], *windows = [NSMutableArray array];
    NSMutableSet *pids = [NSMutableSet set];
    if (argc == 2) [pids addObject:@(atoi(argv[1]))];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (![@[@"ai.tatwo.tatwo2", @"ai.tatwo.tatwo2.staging"] containsObject:app.bundleIdentifier ?: @""]) continue;
        [pids addObject:@(app.processIdentifier)];
        [apps addObject:@{@"bundleID":app.bundleIdentifier, @"pid":@(app.processIdentifier),
            @"name":app.localizedName ?: @"", @"executable":app.executableURL.path ?: @""}];
    }
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    if (!list) { fputs("CGWindowListCopyWindowInfo failed\n", stderr); return 1; }
    for (NSDictionary *w in list) {
        if (![pids containsObject:w[(id)kCGWindowOwnerPID]]) continue;
        [windows addObject:@{@"pid":w[(id)kCGWindowOwnerPID], @"owner":w[(id)kCGWindowOwnerName] ?: @"",
            @"id":w[(id)kCGWindowNumber], @"layer":w[(id)kCGWindowLayer],
            @"visible":w[(id)kCGWindowIsOnscreen] ?: @NO, @"bounds":w[(id)kCGWindowBounds],
            @"alpha":w[(id)kCGWindowAlpha] ?: @0}];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"apps":apps,@"windows":windows} options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
} }
