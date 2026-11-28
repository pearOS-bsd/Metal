/* surface: draws into a texture over an IOSurface (newTextureWithDescriptor:iosurface:plane:, as CAMetalLayer's drawables are) and reads the
 * pixels back from the surface's memory on the CPU (IOSurfaceGetBaseAddress), not through Metal: what the window server sees.
 *   surface LIB.metallib [OUT.ppm]   (LIB: art_vertex + art_fragment of tests/art, see tools/air)
 * Build on a Mac: clang -fobjc-arc -framework Foundation -framework Metal -framework IOSurface tests/surface.m -o surface */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		if (argc < 2) return 2;
		enum { W = 512, H = 512 };
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
		printf("surface: device %s, IOSurface %u (row %zu)\n", dev.name.UTF8String, IOSurfaceGetID(s), IOSurfaceGetBytesPerRow(s));
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td iosurface:s plane:0];
		printf("surface: texture %s (iosurface %s)\n", tex ? "ok" : "FAILED", tex.iosurface == s ? "same" : "different");
		if (!tex) return 1;
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"art_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"art_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!pso) { printf("surface: pipeline: %s\n", e.localizedDescription.UTF8String); return 1; }
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		float aspect = 1;
		id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:pso]; [enc setFragmentBytes:&aspect length:4 atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		const uint8_t *p = IOSurfaceGetBaseAddress(s); size_t row = IOSurfaceGetBytesPerRow(s);
		long lit = 0; for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { const uint8_t *q = p + y * row + x * 4; if (q[0] + q[1] + q[2] > 60) lit++; }
		printf("surface: status %lu, %ld of %d pixels lit in the IOSurface's memory: %s\n", (unsigned long)cb.status, lit, W * H, lit > W * H / 10 ? "ok" : "EMPTY");
		if (argc > 2) {
			NSMutableData *ppm = [NSMutableData dataWithData:[[NSString stringWithFormat:@"P6\n%d %d\n255\n", W, H] dataUsingEncoding:NSASCIIStringEncoding]];
			for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { const uint8_t *q = p + y * row + x * 4; uint8_t rgb[3] = { q[2], q[1], q[0] }; [ppm appendBytes:rgb length:3]; }
			[ppm writeToFile:@(argv[2]) atomically:NO];
		}
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		return lit > W * H / 10 ? 0 : 1;
	}
}
