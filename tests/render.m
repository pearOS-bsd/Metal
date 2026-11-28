/* render: a render pass through the Metal API, checked on the CPU.
 *   render make OUT.metallib   (on a Mac with a GPU: the shaders below compiled by the real Metal, serialized as a dynamic library)
 *   render LIB.metallib        (anywhere: clear an 8x8 RGBA8 texture to blue, draw the top-left quarter orange, read it back, check every texel)
 * Build on a Mac: clang -fobjc-arc -framework Foundation -framework Metal tests/render.m -o render */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
	"struct V { float4 pos [[position]]; float4 color; };\n"
	"vertex V quad_vertex(uint vid [[vertex_id]], constant float2 *pos [[buffer(0)]], constant float4 &color [[buffer(1)]])\n"
	"{ V v; v.pos = float4(pos[vid], 0, 1); v.color = color; return v; }\n"
	"fragment float4 quad_fragment(V in [[stage_in]]) { return in.color; }\n";

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("render: device %s\n", dev ? dev.name.UTF8String : "(none)");
		if (!dev || argc < 2) return 1;
		NSError *e = nil;
		if (argc > 2 && !strcmp(argv[1], "make")) {
			MTLCompileOptions *o = [MTLCompileOptions new]; o.libraryType = MTLLibraryTypeDynamic; o.installName = @"@executable_path/render.metallib";
			id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e];
			id<MTLDynamicLibrary> dyn = lib ? [dev newDynamicLibrary:lib error:&e] : nil;
			BOOL ok = dyn && [dyn serializeToURL:[NSURL fileURLWithPath:@(argv[2])] error:&e];
			printf("render: %s %s\n", ok ? "wrote" : "FAILED", ok ? argv[2] : e.localizedDescription.UTF8String);
			return ok ? 0 : 1;
		}
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
		printf("render: library %s\n", lib ? [lib.functionNames componentsJoinedByString:@" "].UTF8String : e.localizedDescription.UTF8String);
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"quad_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"quad_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
		printf("render: pipeline %s\n", pso ? "ok" : e.localizedDescription.UTF8String);
		if (!pso) return 1;
		enum { S = 8 };
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:S height:S mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
		float pos[12] = { -1, 1, 0, 1, -1, 0, 0, 1, 0, 0, -1, 0 }, color[4] = { 1, 0.2f, 0, 1 };
		id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:pso]; [enc setVertexBytes:pos length:sizeof pos atIndex:0]; [enc setVertexBytes:color length:sizeof color atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[enc endEncoding];
		[cb commit]; [cb waitUntilCompleted];
		unsigned char px[S * S * 4]; [tex getBytes:px bytesPerRow:S * 4 fromRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0];
		int bad = 0;
		for (int y = 0; y < S; y++) { char line[S + 1]; for (int x = 0; x < S; x++) {
			const unsigned char *p = px + (y * S + x) * 4; int in = x < S / 2 && y < S / 2;
			int ok = in ? (p[0] == 255 && p[1] == 51 && p[2] == 0 && p[3] == 255) : (p[0] == 0 && p[1] == 0 && p[2] == 255 && p[3] == 255);
			if (!ok) bad++; line[x] = ok ? (in ? '#' : '.') : '?'; } line[S] = 0; printf("render:   %s\n", line); }
		printf("render: status %lu: %s\n", (unsigned long)cb.status, bad ? "WRONG" : "every texel as expected");
		return bad ? 1 : 0;
	}
}
