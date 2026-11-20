/* mtldevice: asks the real Metal.framework for its devices and prints what it gets.  On a Mac: the GPU.  On pearOS: whatever PearMetalDriver makes of the IOAccelerator node.
 * Build on a Mac: clang -fobjc-arc -framework Foundation -framework Metal tests/mtldevice.m -o mtldevice */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <unistd.h>
int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
		printf("mtldevice: MTLCopyAllDevices: %lu device(s)\n", (unsigned long)all.count);
		for (id<MTLDevice> d in all) printf("mtldevice:   %s (registryID %llu, lowPower %d, unified %d)\n", d.name.UTF8String, d.registryID, (int)d.isLowPower, (int)d.hasUnifiedMemory);
		if (all.count == 0) { sleep(4); all = MTLCopyAllDevices(); printf("mtldevice: after 4 s: %lu device(s)\n", (unsigned long)all.count); }
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("mtldevice: MTLCreateSystemDefaultDevice: %s\n", dev ? dev.name.UTF8String : "(nil)");
		if (dev) {
			id<MTLCommandQueue> q = [dev newCommandQueue];
			printf("mtldevice: newCommandQueue: %s\n", q ? "ok" : "(nil)");
			id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			printf("mtldevice: newBuffer: %s\n", b ? "ok" : "(nil)");
		}
	}
	return 0;
}
