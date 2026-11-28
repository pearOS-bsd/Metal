/* compute: a compute dispatch through the Metal API, checked on the CPU.
 *   compute make OUT.metallib   (on a Mac with a GPU: the kernel below compiled by the real Metal, serialized as a dynamic library)
 *   compute LIB.metallib        (anywhere: load it, run scale_and_offset over 1000 floats, check out[i] = in[i] * 2 + i)
 * Build on a Mac: clang -fobjc-arc -framework Foundation -framework Metal tests/compute.m -o compute */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
	"kernel void scale_and_offset(device const float *in [[buffer(0)]], device float *out [[buffer(1)]], constant float &scale [[buffer(2)]], uint i [[thread_position_in_grid]])\n"
	"{ out[i] = in[i] * scale + float(i); }\n";

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("compute: device %s\n", dev ? dev.name.UTF8String : "(none)");
		if (!dev || argc < 2) return 1;
		NSError *e = nil;
		if (argc > 2 && !strcmp(argv[1], "make")) {
			MTLCompileOptions *o = [MTLCompileOptions new]; o.libraryType = MTLLibraryTypeDynamic; o.installName = @"@executable_path/compute.metallib";
			id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e];
			id<MTLDynamicLibrary> dyn = lib ? [dev newDynamicLibrary:lib error:&e] : nil;
			BOOL ok = dyn && [dyn serializeToURL:[NSURL fileURLWithPath:@(argv[2])] error:&e];
			printf("compute: %s %s\n", ok ? "wrote" : "FAILED", ok ? argv[2] : e.localizedDescription.UTF8String);
			return ok ? 0 : 1;
		}
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
		printf("compute: library %s, functions %s\n", lib ? "ok" : e.localizedDescription.UTF8String, lib ? [lib.functionNames componentsJoinedByString:@" "].UTF8String : "-");
		id<MTLFunction> f = [lib newFunctionWithName:@"scale_and_offset"];
		id<MTLComputePipelineState> pso = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
		printf("compute: pipeline %s (max %lu threads, width %lu)\n", pso ? "ok" : e.localizedDescription.UTF8String, (unsigned long)pso.maxTotalThreadsPerThreadgroup, (unsigned long)pso.threadExecutionWidth);
		if (!pso) return 1;
		enum { N = 1000 };
		id<MTLBuffer> in = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared], out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
		float *ip = in.contents, scale = 2; for (int i = 0; i < N; i++) ip[i] = (float)i;
		memset(out.contents, 0, N * 4);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		__block int handler = 0; [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { (void)b; handler = 1; }];
		id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
		[enc setComputePipelineState:pso]; [enc setBuffer:in offset:0 atIndex:0]; [enc setBuffer:out offset:0 atIndex:1]; [enc setBytes:&scale length:4 atIndex:2];
		[enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		[enc endEncoding];
		[cb commit]; [cb waitUntilCompleted];
		const float *op = out.contents; int bad = 0; for (int i = 0; i < N; i++) if (op[i] != 3.0f * i) bad++;
		printf("compute: status %lu, handler %d, out[0..3] = %g %g %g %g, out[999] = %g: %s\n", (unsigned long)cb.status, handler, op[0], op[1], op[2], op[3], op[N - 1], bad ? "WRONG" : "ok");
		return bad ? 1 : 0;
	}
}
