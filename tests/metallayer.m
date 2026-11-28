/* metallayer: an AppKit window whose view is backed by a CAMetalLayer; a timer draws the art shader (tests/art) into the layer's next drawable and
 * presents it, 30 times a second.  Logs the drawables (their IOSurfaces) every 30 frames; after 60 frames writes the pixels of the last drawable's
 * IOSurface to /tmp/metallayer.ppm (what the window server should show).
 *   metallayer LIB.metallib
 * Build on a Mac: clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore -framework IOSurface tests/metallayer.m -o metallayer */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>

@interface MLView : NSView @end
@implementation MLView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
@end

static id<MTLDevice> dev; static id<MTLCommandQueue> queue; static id<MTLRenderPipelineState> pso; static CAMetalLayer *ml; static int frames;

static void draw_frame(void)
{
	@autoreleasepool {
		id<CAMetalDrawable> d = [ml nextDrawable];
		if (!d) { if (frames % 30 == 0) printf("metallayer: frame %d: no drawable\n", frames); frames++; return; }
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		float aspect = (float)d.texture.width / (float)d.texture.height * (1.0f + 0.35f * sinf(frames * 0.05f));	/* animated: the picture breathes, so a screenshot shows whether the window follows the frames */
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:pso]; [enc setFragmentBytes:&aspect length:4 atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
		[cb presentDrawable:d];
		[cb commit];
		if (frames % 30 == 0) { IOSurfaceRef s = d.texture.iosurface; printf("metallayer: frame %d: drawable %lux%lu, format %lu, IOSurface %u\n", frames, (unsigned long)d.texture.width, (unsigned long)d.texture.height, (unsigned long)d.texture.pixelFormat, s ? IOSurfaceGetID(s) : 0); }
		if (frames == 60) {
			[cb waitUntilCompleted];
			IOSurfaceRef s = d.texture.iosurface;
			if (s) {
				IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
				size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), row = IOSurfaceGetBytesPerRow(s); const uint8_t *p = IOSurfaceGetBaseAddress(s);
				FILE *f = fopen("/tmp/metallayer.ppm", "wb"); fprintf(f, "P6\n%zu %zu\n255\n", w, h);
				for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { const uint8_t *q = p + y * row + x * 4; fputc(q[2], f); fputc(q[1], f); fputc(q[0], f); }
				fclose(f); IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
				printf("metallayer: wrote /tmp/metallayer.ppm (%zux%zu)\n", w, h);
			}
		}
		frames++;
	}
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		if (argc < 2) return 2;
		[NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		dev = MTLCreateSystemDefaultDevice(); queue = [dev newCommandQueue]; NSError *e = nil;
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"art_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"art_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
		printf("metallayer: device %s, pipeline %s\n", dev.name.UTF8String, pso ? "ok" : e.localizedDescription.UTF8String);
		if (!pso) return 1;
		NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 480, 360) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
		w.title = @"Metal on pearOS";
		MLView *v = [[MLView alloc] initWithFrame:NSMakeRect(0, 0, 480, 360)]; v.wantsLayer = YES; w.contentView = v;
		ml = (CAMetalLayer *)v.layer; ml.device = dev; ml.pixelFormat = MTLPixelFormatBGRA8Unorm; ml.framebufferOnly = NO;
		ml.drawableSize = CGSizeMake(480 * w.backingScaleFactor, 360 * w.backingScaleFactor);
		printf("metallayer: layer %s, drawable size %gx%g\n", [NSStringFromClass([ml class]) UTF8String], ml.drawableSize.width, ml.drawableSize.height);
		[w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
		[NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) { (void)t; draw_frame(); }];
		[NSApp run];
	}
	return 0;
}
