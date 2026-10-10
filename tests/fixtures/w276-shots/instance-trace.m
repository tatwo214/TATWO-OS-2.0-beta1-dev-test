#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static id (*original)(id,SEL,id);
static id trace(id self, SEL cmd, id bundle) {
 id list=original(self,cmd,bundle);
 fprintf(stderr,"INSTANCE_TRACE self=%d bundle=%s count=%lu\n",getpid(),[bundle UTF8String],(unsigned long)[list count]);
 for (NSRunningApplication *app in list) fprintf(stderr,"INSTANCE_TRACE sibling_pid=%d executable=%s\n",app.processIdentifier,app.executableURL.path.UTF8String);
 return list;
}
__attribute__((constructor)) static void install(void) {
 Method method=class_getClassMethod(NSRunningApplication.class,@selector(runningApplicationsWithBundleIdentifier:));
 original=(void*)method_getImplementation(method); method_setImplementation(method,(IMP)trace);
}
