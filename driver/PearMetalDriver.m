/* PearMetalDriver: the Metal driver bundle of pearOS.  Apple's Metal.framework finds it through the IOAccelerator node of the registry (properties MetalPluginName =
 * PearMetalDriver, MetalPluginClassName = PearMTLDevice), loads it from /System/Library/Extensions and makes the device: [[PearMTLDevice alloc] initWithAcceleratorPort:].
 * Built without ARC: the base classes of Apple's Metal were written for an accelerator and their dealloc must not run on an object that never got one.
 * Status: the class is instantiated by the real Metal; the device answers a first set of queries; everything else is traced (see `trace`) to learn what Metal asks next. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static void say(const char *s) { write(2, s, strlen(s)); }
static void trace(const char *what, SEL sel) { char b[240]; snprintf(b, sizeof b, "PearMetalDriver: %s %s\n", what, sel ? sel_getName(sel) : ""); say(b); }

/* Apple's classes in Metal.framework, found at run time (the bundle is linked with -undefined dynamic_lookup) */
@interface MTLIOAccelDevice : NSObject
@end

@interface PearMTLDevice : MTLIOAccelDevice <MTLDevice>
@end

@implementation PearMTLDevice
+ (void)load
{
	/* the private protocols that MTLAddDevice asserts the device conforms to: added from Metal's own objects at run time (they are not in the SDK) */
	static const char *names[] = { "MTLDeviceSPI", NULL };
	for (int i = 0; names[i]; i++) {
		Protocol *p = objc_getProtocol(names[i]);
		char b[100];

		if (p) {
			class_addProtocol(self, p);
			if (getenv("PEAR_METAL_LIST")) for (int req = 1; req >= 0; req--) {	/* the work list: every method of the protocol, required first */
				unsigned n = 0; struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, YES, &n);
				for (unsigned k = 0; k < n; k++) { snprintf(b, sizeof b, "PearMetalDriver: %s %s %s\n", names[i], req ? "required" : "optional", sel_getName(d[k].name)); say(b); }
				free(d);
			}
		}
		snprintf(b, sizeof b, "PearMetalDriver: protocol %s %s\n", names[i], p ? "added" : "NOT FOUND"); say(b);
	}
	say("PearMetalDriver: bundle loaded, class PearMTLDevice\n");
}
- (instancetype)initWithAcceleratorPort:(unsigned)port { char b[100]; snprintf(b, sizeof b, "PearMetalDriver: initWithAcceleratorPort: %u\n", port); say(b); return self; }
- (void)dealloc { say("PearMetalDriver: dealloc (the base class dealloc is not run)\n"); }
- (unsigned long)featureProfile { return 10002; }
- (NSString *)name { return @"Pear Software GPU"; }
- (uint64_t)registryID { return 0x100000100ULL; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return YES; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (NSUInteger)registryIDHigh { return 1; }
/* whatever else Metal sends that the base classes do not answer is named here (they crash on an accelerator that is not there: the next thing to implement) */
+ (BOOL)resolveInstanceMethod:(SEL)sel { trace("instance selector asked and not implemented:", sel); return [super resolveInstanceMethod:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { trace("forwardInvocation:", inv.selector); }
@end
