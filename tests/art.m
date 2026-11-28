/* art: a full-screen fragment shader (Mandelbrot with a rainbow palette and glowing rings) rendered by the Metal API into a
 * 768 x 768 texture, read back and written as a binary PPM.  Shows that a real picture comes out of PearMetalDriver + the helper.
 *   art LIB.metallib OUT.ppm      (LIB: art_vertex + art_fragment, see tools/air)
 * Build on a Mac: clang -fobjc-arc -framework Foundation -framework Metal tests/art.m -o art */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		if (argc < 3) return 2;
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
		printf("art: device %s\n", dev.name.UTF8String);
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"art_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"art_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!pso) { printf("art: pipeline: %s\n", e.localizedDescription.UTF8String); return 1; }
		enum { W = 768, H = 768 };
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		float aspect = (float)W / H;
		NSDate *t0 = [NSDate date];
		id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:pso]; [enc setFragmentBytes:&aspect length:4 atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
		printf("art: status %lu, %.0f ms\n", (unsigned long)cb.status, -[t0 timeIntervalSinceNow] * 1000);
		unsigned char *px = malloc(W * H * 4); [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		NSMutableData *ppm = [NSMutableData dataWithData:[[NSString stringWithFormat:@"P6\n%d %d\n255\n", W, H] dataUsingEncoding:NSASCIIStringEncoding]];
		for (int i = 0; i < W * H; i++) [ppm appendBytes:px + i * 4 length:3];
		BOOL ok = [ppm writeToFile:@(argv[2]) options:0 error:&e];
		printf("art: %s %s\n", ok ? "wrote" : "could not write", ok ? argv[2] : e.description.UTF8String);
	}
	return 0;
}
