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
			if (b) { memset(b.contents, 0x5a, 16); printf("mtldevice: buffer length %lu, contents[0] = 0x%02x, storage %lu\n", (unsigned long)b.length, ((unsigned char *)b.contents)[0], (unsigned long)b.storageMode); }
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];
			printf("mtldevice: newTexture: %s", t ? "ok" : "(nil)");
			if (t) {
				unsigned px[4] = { 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00 }, back[4] = { 0 };
				[t replaceRegion:MTLRegionMake2D(2, 1, 4, 1) mipmapLevel:0 withBytes:px bytesPerRow:16];
				[t getBytes:back bytesPerRow:16 fromRegion:MTLRegionMake2D(2, 1, 4, 1) mipmapLevel:0];
				printf(" %lux%lu format %lu, readback %s", (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, memcmp(px, back, 16) == 0 ? "ok" : "WRONG");
			}
			printf("\n");
		}
	}
	return 0;
}
