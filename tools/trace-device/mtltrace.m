/* mtltrace: measuring tool, not part of Metal.framework.  Interposes MTLCreateSystemDefaultDevice / MTLCopyAllDevices of the real Metal.framework and answers with an
 * object that implements the MTLDevice protocol by name only: every selector that a client sends is written to $MTLTRACE_LOG (default /tmp/mtltrace.log) with the
 * signature from the protocol, and answered with zero / nil.  It shows what RenderBox, SwiftUI and CoreImage ask of a device, in order, which is the work list of Metal.
 * Run:  DYLD_INSERT_LIBRARIES=/path/libmtltrace.dylib app    Build on a Mac: sh build.sh */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *logf_(void)
{
	static FILE *f; static dispatch_once_t once;
	dispatch_once(&once, ^{ const char *p = getenv("MTLTRACE_LOG"); f = fopen(p ? p : "/tmp/mtltrace.log", "a"); if (f) setvbuf(f, NULL, _IOLBF, 0); });
	return f;
}

@interface PearTraceObject : NSObject { @public Protocol *proto; NSString *label; }
@end
@implementation PearTraceObject
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	struct objc_method_description d = protocol_getMethodDescription(proto, sel, YES, YES);
	if (d.name == NULL) d = protocol_getMethodDescription(proto, sel, NO, YES);
	if (d.name == NULL) d = protocol_getMethodDescription(@protocol(NSObject), sel, YES, YES);
	if (d.name != NULL) return [NSMethodSignature signatureWithObjCTypes:d.types];
	return [super methodSignatureForSelector:sel];
}
- (BOOL)respondsToSelector:(SEL)sel
{
	struct objc_method_description d = protocol_getMethodDescription(proto, sel, YES, YES);
	if (d.name == NULL) d = protocol_getMethodDescription(proto, sel, NO, YES);
	return d.name != NULL || [super respondsToSelector:sel];
}
- (BOOL)conformsToProtocol:(Protocol *)p { return protocol_conformsToProtocol(proto, p) || [super conformsToProtocol:p]; }
- (BOOL)isKindOfClass:(Class)c { return [super isKindOfClass:c]; }
- (void)forwardInvocation:(NSInvocation *)inv
{
	FILE *f = logf_();
	NSMethodSignature *ms = inv.methodSignature;
	const char *rt = ms.methodReturnType;
	char buf[64]; memset(buf, 0, sizeof buf);

	if (f) fprintf(f, "%s %s  (returns %s)\n", label.UTF8String, sel_getName(inv.selector), rt);
	if (rt[0] == '@') {
		/* name / label style properties are asked as objects: give a string, everything else nil */
		NSString *s = [NSStringFromSelector(inv.selector) isEqualToString:@"name"] ? @"Pear Software Device" : nil;
		[inv setReturnValue:&s];
	} else if (rt[0] != 'v' && ms.methodReturnLength <= sizeof buf) {
		[inv setReturnValue:buf];
	}
}
@end

static id gDevice;
static id make_device(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		PearTraceObject *o = [PearTraceObject new];
		o->proto = @protocol(MTLDevice); o->label = @"MTLDevice";
		gDevice = o;
		if (logf_()) fprintf(logf_(), "== mtltrace: device created in %s\n", getprogname());
	});
	return gDevice;
}

static id pear_MTLCreateSystemDefaultDevice(void) { return make_device(); }
static NSArray *pear_MTLCopyAllDevices(void) { return @[ make_device() ]; }

typedef struct { const void *replacement; const void *replacee; } interpose_t;
__attribute__((used)) static const interpose_t interposers[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)pear_MTLCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice },
	{ (const void *)pear_MTLCopyAllDevices, (const void *)MTLCopyAllDevices },
};
