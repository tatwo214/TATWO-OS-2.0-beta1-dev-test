// OS loader probe: record and refuse native credential APIs, never forward to a real Keychain.
#include <Security/Security.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <string.h>
static int trace_fd = -1;
__attribute__((constructor)) static void attach(void) {
    trace_fd = open(getenv("W293_KEYCHAIN_TRACE"), O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (trace_fd < 0) _exit(86);
    dprintf(trace_fd, "%d attached\n", getpid());
}
static OSStatus refuse(const char *api) {
    if (dprintf(trace_fd, "%d call %s\n", getpid(), api) < 0) _exit(86);
    return errSecInteractionNotAllowed;
}
#define BIND(replacement, original) \
    __attribute__((used)) static struct { const void *r, *o; } pair_##original \
    __attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement, (const void *)&original}
// The product is loaded after this fail-closed observer at process startup.
// Any call here is a missed product interposition: record it and never forward.
static OSStatus probeCopy(CFDictionaryRef q, CFTypeRef *r) {
    if (r) *r = NULL; return refuse("SecItemCopyMatching");
}
static OSStatus probeAdd(CFDictionaryRef q, CFTypeRef *r) { if (r) *r = NULL; return refuse("SecItemAdd"); }
static OSStatus probeUpdate(CFDictionaryRef q, CFDictionaryRef a) { return refuse("SecItemUpdate"); }
static OSStatus probeDelete(CFDictionaryRef q) { return refuse("SecItemDelete"); }
static OSStatus probeGetInteraction(Boolean *a) { if (a) *a = false; return refuse("SecKeychainGetUserInteractionAllowed"); }
static OSStatus probeSetInteraction(Boolean a) { return refuse("SecKeychainSetUserInteractionAllowed"); }
static OSStatus probeFind(CFTypeRef k, UInt32 sn, const char *s, UInt32 an, const char *a, UInt32 *n, void **p, SecKeychainItemRef *i) {
    if (n) *n = 0; if (p) *p = NULL; if (i) *i = NULL; return refuse("SecKeychainFindGenericPassword");
}
static OSStatus probeGenericAdd(SecKeychainRef k, UInt32 sn, const char *s, UInt32 an, const char *a, UInt32 n, const void *p, SecKeychainItemRef *i) {
    if (i) *i = NULL; return refuse("SecKeychainAddGenericPassword");
}
BIND(probeCopy, SecItemCopyMatching);
BIND(probeAdd, SecItemAdd);
BIND(probeUpdate, SecItemUpdate);
BIND(probeDelete, SecItemDelete);
BIND(probeGetInteraction, SecKeychainGetUserInteractionAllowed);
BIND(probeSetInteraction, SecKeychainSetUserInteractionAllowed);
BIND(probeFind, SecKeychainFindGenericPassword);
BIND(probeGenericAdd, SecKeychainAddGenericPassword);
