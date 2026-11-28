/* PearMetalDriver: the Metal driver bundle of pearOS.  Apple's Metal.framework finds it through the IOAccelerator node of the registry (properties MetalPluginName =
 * PearMetalDriver, MetalPluginClassName = PearMTLDevice), loads it from /System/Library/Extensions and makes the device: [[PearMTLDevice alloc] initWithAcceleratorPort:].
 * Built without ARC: the base classes of Apple's Metal were written for an accelerator and their dealloc must not run on an object that never got one.
 * Status: the class is instantiated by the real Metal; the device answers a first set of queries; everything else is traced (see `trace`) to learn what Metal asks next. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "pmw.h"

extern void instrumentObjcMessageSends(BOOL);
static void say(const char *s) { write(2, s, strlen(s)); }
static void trace(const char *what, SEL sel) { char b[240]; snprintf(b, sizeof b, "PearMetalDriver: %s %s\n", what, sel ? sel_getName(sel) : ""); say(b); }

/* ---- the Vulkan helper (pmw.h): one connection per process, a reader thread that hands every reply to the request with its seq ---- */
typedef void (^pmw_done)(uint32_t status, NSData *answer);
static int pmw_fd = -1;
static pthread_mutex_t pmw_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pmw_cv = PTHREAD_COND_INITIALIZER;
static uint64_t pmw_seq;
static NSMutableDictionary *pmw_waiting;		/* seq -> pmw_done (asynchronous requests) or a NSMutableArray slot (synchronous ones) */

static int pmw_read_all(int fd, void *p, size_t n) { size_t got = 0; while (got < n) { ssize_t k = read(fd, (char *)p + got, n - got); if (k <= 0) return -1; got += (size_t)k; } return 0; }
static void *pmw_reader(void *arg)
{
	(void)arg;
	for (;;) {
		pmw_rep rp; if (pmw_read_all(pmw_fd, &rp, sizeof rp)) break;
		NSMutableData *ans = [[NSMutableData alloc] initWithLength:rp.len];
		if (rp.len && pmw_read_all(pmw_fd, ans.mutableBytes, rp.len)) { [ans release]; break; }
		pthread_mutex_lock(&pmw_mx);
		id w = [[pmw_waiting objectForKey:@(rp.seq)] retain]; [pmw_waiting removeObjectForKey:@(rp.seq)];
		if ([w isKindOfClass:[NSMutableArray class]]) { [(NSMutableArray *)w addObject:@(rp.status)]; [(NSMutableArray *)w addObject:ans]; pthread_cond_broadcast(&pmw_cv); }
		pthread_mutex_unlock(&pmw_mx);
		if (w && ![w isKindOfClass:[NSMutableArray class]]) ((pmw_done)w)(rp.status, ans);
		[w release]; [ans release];
	}
	say("PearMetalDriver: the Vulkan helper went away\n");
	return NULL;
}
static int pmw_connect(void)
{
	if (pmw_fd >= 0) return 0;
	const char *path = getenv("PEAR_METAL_SOCKET") ? getenv("PEAR_METAL_SOCKET") : PMW_SOCKET;
	struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX; strncpy(a.sun_path, path, sizeof a.sun_path - 1);
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { if (fd >= 0) close(fd); char b[200]; snprintf(b, sizeof b, "PearMetalDriver: no Vulkan helper at %s\n", path); say(b); return -1; }
	pmw_fd = fd; pmw_waiting = [[NSMutableDictionary alloc] init];
	pthread_t t; pthread_create(&t, NULL, pmw_reader, NULL); pthread_detach(t);
	return 0;
}
/* sends a request; with done == nil waits for the reply (status returned, the answer in *answer, autoreleased) */
static uint32_t pmw_send(uint32_t op, const void *body, size_t len, NSData **answer, pmw_done done)
{
	pthread_mutex_lock(&pmw_mx);
	if (pmw_connect() != 0) { pthread_mutex_unlock(&pmw_mx); if (done) done(2, nil); return 2; }
	pmw_hdr h = { op, (uint32_t)len, ++pmw_seq };
	NSMutableArray *slot = done ? nil : [NSMutableArray array];
	[pmw_waiting setObject:(done ? (id)[[done copy] autorelease] : (id)slot) forKey:@(h.seq)];
	struct iovec v[2] = { { &h, sizeof h }, { (void *)body, len } };
	(void)v;
	write(pmw_fd, &h, sizeof h); if (len) write(pmw_fd, body, len);
	if (done) { pthread_mutex_unlock(&pmw_mx); return 0; }
	while (slot.count < 2) pthread_cond_wait(&pmw_cv, &pmw_mx);
	uint32_t st = [slot[0] unsignedIntValue]; if (answer) *answer = slot[1];
	pthread_mutex_unlock(&pmw_mx);
	if (st) { NSData *a = slot[1]; char b[300]; snprintf(b, sizeof b, "PearMetalDriver: request %u failed: %.*s\n", op, (int)MIN(a.length, (NSUInteger)250), (const char *)a.bytes); say(b); }
	return st;
}
static uint64_t pmw_u64(NSData *d, size_t off) { uint64_t v = 0; if (d.length >= off + 8) memcpy(&v, (const char *)d.bytes + off, 8); return v; }
static uint32_t pmw_u32(NSData *d, size_t off) { uint32_t v = 0; if (d.length >= off + 4) memcpy(&v, (const char *)d.bytes + off, 4); return v; }
static void pmw_release(uint64_t h) { if (h && pmw_fd >= 0) pmw_send(PMW_RELEASE, &h, 8, NULL, ^(uint32_t st, NSData *a) { (void)st; (void)a; }); }
static NSError *pmw_error(NSString *what, NSData *a) { return [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:3 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", what, a ? [[[NSString alloc] initWithData:a encoding:NSUTF8StringEncoding] autorelease] : @"no Vulkan helper"] }]; }

/* Apple's classes in Metal.framework, found at run time (the bundle is linked with -undefined dynamic_lookup) */
@interface MTLIOAccelDevice : NSObject
@end

@interface PearMTLCommandQueue : NSObject <MTLCommandQueue>
{ id<MTLDevice> _device; NSString *_label; }
- (instancetype)initWithDevice:(id<MTLDevice>)d;
@end

@interface PearMTLDevice : MTLIOAccelDevice <MTLDevice>
{ unsigned _acc; }
@end


/* ---- resources: plain memory.  A GPU resource of this device is host memory; the Vulkan helper will map or copy it when a command buffer that uses it runs. ---- */

static size_t pear_bytes_per_pixel(MTLPixelFormat f)
{
	switch (f) {
	case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatStencil8: return 1;
	case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: case MTLPixelFormatDepth16Unorm: return 2;
	case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
	case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
	case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: case MTLPixelFormatDepth32Float: case MTLPixelFormatBGR10A2Unorm: return 4;
	case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatDepth32Float_Stencil8: return 8;
	case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
	default: return 4;	/* compressed and the formats of other GPUs: 4 bytes a pixel is enough as a size for now */
	}
}

@interface PearMTLBuffer : NSObject <MTLBuffer>
{ @public id<MTLDevice> _device; NSString *_label; void *_mem; NSUInteger _length; MTLResourceOptions _options; BOOL _owned; void (^_dealloc)(void *, NSUInteger); uint64_t _h, _gpu; size_t _maplen; }
@end

@implementation PearMTLBuffer
- (void)dealloc
{
	pmw_release(_h);
	if (_dealloc) _dealloc(_mem, _length); else if (_maplen) munmap(_mem, _maplen); else if (_owned) free(_mem);
	[_dealloc release]; [_label release]; [super dealloc];
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (void *)contents { return _mem; }
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return _length; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options >> 4) & 0xf); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & 0xf); }
- (MTLHazardTrackingMode)hazardTrackingMode { return (MTLHazardTrackingMode)((_options >> 8) & 0x3); }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)st { return MTLPurgeableStateNonVolatile; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (void)didModifyRange:(NSRange)r {}
- (void)addDebugMarker:(NSString *)m range:(NSRange)r {}
- (void)removeAllDebugMarkers {}
- (uint64_t)gpuAddress { return _gpu ? _gpu : (uint64_t)(uintptr_t)_mem; }
- (id)remoteStorageBuffer { return nil; }
@end

@interface PearMTLTexture : NSObject <MTLTexture>
{ @public id<MTLDevice> _device; NSString *_label; void *_mem; size_t _size; MTLTextureDescriptor *_desc; }
@end

@implementation PearMTLTexture
- (void)dealloc { free(_mem); [_desc release]; [_label release]; [super dealloc]; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (MTLTextureType)textureType { return _desc.textureType; }
- (MTLPixelFormat)pixelFormat { return _desc.pixelFormat; }
- (NSUInteger)width { return _desc.width; }
- (NSUInteger)height { return _desc.height; }
- (NSUInteger)depth { return _desc.depth; }
- (NSUInteger)mipmapLevelCount { return _desc.mipmapLevelCount; }
- (NSUInteger)sampleCount { return _desc.sampleCount; }
- (NSUInteger)arrayLength { return _desc.arrayLength; }
- (MTLTextureUsage)usage { return _desc.usage; }
- (MTLResourceOptions)resourceOptions { return _desc.resourceOptions; }
- (MTLStorageMode)storageMode { return _desc.storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _desc.cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _desc.hazardTrackingMode; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (NSUInteger)allocatedSize { return _size; }
- (id<MTLTexture>)parentTexture { return nil; }
- (NSUInteger)parentRelativeLevel { return 0; }
- (NSUInteger)parentRelativeSlice { return 0; }
- (id<MTLBuffer>)buffer { return nil; }
- (NSUInteger)bufferOffset { return 0; }
- (NSUInteger)bufferBytesPerRow { return 0; }
- (IOSurfaceRef)iosurface { return NULL; }
- (NSUInteger)iosurfacePlane { return 0; }
- (BOOL)isShareable { return NO; }
- (BOOL)isSparse { return NO; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)st { return MTLPurgeableStateNonVolatile; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl
{
	size_t bpp = pear_bytes_per_pixel(_desc.pixelFormat), rowsize = _desc.width * bpp;
	for (NSUInteger y = 0; y < r.size.height && lvl == 0; y++)
		memcpy((char *)dst + y * bpr, (char *)_mem + (r.origin.y + y) * rowsize + r.origin.x * bpp, r.size.width * bpp);
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)lvl withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr
{
	size_t bpp = pear_bytes_per_pixel(_desc.pixelFormat), rowsize = _desc.width * bpp;
	for (NSUInteger y = 0; y < r.size.height && lvl == 0; y++)
		memcpy((char *)_mem + (r.origin.y + y) * rowsize + r.origin.x * bpp, (const char *)src + y * bpr, r.size.width * bpp);
}
@end


/* ---- libraries, functions, pipelines: objects of the helper, named by a handle ---- */
@interface PearMTLFunction : NSObject <MTLFunction>
{ @public id<MTLDevice> _device; NSString *_name, *_label; uint64_t _h; MTLFunctionType _type; }
@end
@implementation PearMTLFunction
- (void)dealloc { pmw_release(_h); [_name release]; [_label release]; [super dealloc]; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)name { return _name; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (MTLFunctionType)functionType { return _type; }
- (MTLPatchType)patchType { return MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount { return -1; }
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes { return @[]; }
- (NSDictionary *)functionConstantsDictionary { return @{}; }
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
@end

@interface PearMTLLibrary : NSObject <MTLLibrary>
{ @public id<MTLDevice> _device; NSString *_label, *_installName; NSArray<NSString *> *_names; uint64_t _h; }
@end
@implementation PearMTLLibrary
- (void)dealloc { pmw_release(_h); [_names release]; [_label release]; [_installName release]; [super dealloc]; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (NSArray<NSString *> *)functionNames { return _names; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return _installName; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	NSMutableData *q = [NSMutableData dataWithBytes:&_h length:8]; [q appendBytes:name.UTF8String length:strlen(name.UTF8String) + 1];
	NSData *a = nil;
	if (pmw_send(PMW_FUNCTION_NEW, q.bytes, q.length, &a, nil) != 0) return nil;
	PearMTLFunction *f = [[PearMTLFunction alloc] init]; f->_device = _device; f->_name = [name copy]; f->_h = pmw_u64(a, 0); f->_type = (MTLFunctionType)pmw_u32(a, 8);
	return f;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)v error:(NSError **)e { trace("library constantValues (ignored)", NULL); id f = [self newFunctionWithName:name]; if (!f && e) *e = pmw_error(name, nil); return f; }
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)e { return [self newFunctionWithName:d.name constantValues:d.constantValues error:e]; }
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)v completionHandler:(void (^)(id<MTLFunction>, NSError *))h { NSError *e = nil; id f = [self newFunctionWithName:name constantValues:v error:&e]; h(f, e); [f release]; }
@end

@interface PearMTLComputePipelineState : NSObject <MTLComputePipelineState>
{ @public id<MTLDevice> _device; NSString *_label; uint64_t _h; NSUInteger _maxThreads, _width, _staticTG; }
@end
@implementation PearMTLComputePipelineState
- (void)dealloc { pmw_release(_h); [_label release]; [super dealloc]; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxThreads; }
- (NSUInteger)threadExecutionWidth { return _width; }
- (NSUInteger)staticThreadgroupMemoryLength { return _staticTG; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { return 0; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _h; return r; }
@end

/* ---- command buffers: the commands are recorded here (pmw_cmd records) and sent whole at commit ---- */
@class PearMTLCommandBuffer;
static void pmw_rec(NSMutableData *l, uint16_t code, const void *args, size_t n) { uint16_t h[2] = { code, (uint16_t)(4 + n) }; [l appendBytes:h length:4]; if (n) [l appendBytes:args length:n]; }

@interface PearMTLCommandBuffer : NSObject <MTLCommandBuffer>
{ @public id<MTLCommandQueue> _queue; NSString *_label; NSMutableData *_list; NSMutableArray *_keep, *_completed, *_scheduled; MTLCommandBufferStatus _status; NSError *_error; uint64_t _sid; pthread_mutex_t _mx; pthread_cond_t _cv; }
- (void)pear_keep:(id)o;
@end

@interface PearMTLComputeCommandEncoder : NSObject <MTLComputeCommandEncoder>
{ @public PearMTLCommandBuffer *_cb; NSString *_label; }
@end
@implementation PearMTLComputeCommandEncoder
- (void)dealloc { [_label release]; [super dealloc]; }
- (id<MTLDevice>)device { return _cb.device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)p { [_cb pear_keep:p]; uint64_t h = ((PearMTLComputePipelineState *)p)->_h; pmw_rec(_cb->_list, PMWC_SET_COMPUTE_PSO, &h, 8); }
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off atIndex:(NSUInteger)i { [_cb pear_keep:b]; struct { uint32_t st, idx; uint64_t h, off; } a = { 0, (uint32_t)i, b ? ((PearMTLBuffer *)b)->_h : 0, off }; pmw_rec(_cb->_list, PMWC_SET_BUFFER, &a, sizeof a); }
- (void)setBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i { trace("compute setBufferOffset (not kept)", NULL); }
- (void)setBuffers:(const id<MTLBuffer> *)bs offsets:(const NSUInteger *)offs withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:bs[k] offset:offs[k] atIndex:r.location + k]; }
- (void)setBytes:(const void *)bytes length:(NSUInteger)n atIndex:(NSUInteger)i { NSMutableData *a = [NSMutableData dataWithLength:8]; uint32_t *w = a.mutableBytes; w[0] = 0; w[1] = (uint32_t)i; [a appendBytes:bytes length:n]; pmw_rec(_cb->_list, PMWC_SET_BYTES, a.bytes, a.length); }
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i { uint32_t a[2] = { (uint32_t)i, (uint32_t)n }; pmw_rec(_cb->_list, PMWC_SET_TG_MEMORY, a, 8); }
- (void)dispatchThreads:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { uint64_t a[6] = { g.width, g.height, g.depth, t.width, t.height, t.depth }; pmw_rec(_cb->_list, PMWC_DISPATCH_THREADS, a, sizeof a); }
- (void)dispatchThreadgroups:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { uint64_t a[6] = { g.width, g.height, g.depth, t.width, t.height, t.depth }; pmw_rec(_cb->_list, PMWC_DISPATCH_TGROUPS, a, sizeof a); }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {}
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u {}
- (void)useHeap:(id<MTLHeap>)h {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s {}
- (void)memoryBarrierWithResources:(const id<MTLResource> *)r count:(NSUInteger)n {}
- (void)updateFence:(id<MTLFence>)f {}
- (void)waitForFence:(id<MTLFence>)f {}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}
- (void)endEncoding { pmw_rec(_cb->_list, PMWC_END, NULL, 0); }
@end

@interface PearMTLBlitCommandEncoder : NSObject <MTLBlitCommandEncoder>
{ @public PearMTLCommandBuffer *_cb; NSString *_label; }
@end
@implementation PearMTLBlitCommandEncoder
- (void)dealloc { [_label release]; [super dealloc]; }
- (id<MTLDevice>)device { return _cb.device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)dof size:(NSUInteger)n { [_cb pear_keep:s]; [_cb pear_keep:d]; uint64_t a[5] = { ((PearMTLBuffer *)s)->_h, so, ((PearMTLBuffer *)d)->_h, dof, n }; pmw_rec(_cb->_list, PMWC_COPY_BUF, a, sizeof a); }
- (void)fillBuffer:(id<MTLBuffer>)b range:(NSRange)r value:(uint8_t)v { [_cb pear_keep:b]; struct { uint64_t h, off, n; uint32_t v; } __attribute__((packed)) a = { ((PearMTLBuffer *)b)->_h, r.location, r.length, v }; pmw_rec(_cb->_list, PMWC_FILL_BUF, &a, sizeof a); }
- (void)synchronizeResource:(id<MTLResource>)r {}
- (void)synchronizeTexture:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l {}
- (void)updateFence:(id<MTLFence>)f {}
- (void)waitForFence:(id<MTLFence>)f {}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}
- (void)endEncoding { pmw_rec(_cb->_list, PMWC_END, NULL, 0); }
@end

@implementation PearMTLCommandBuffer
- (instancetype)initWithQueue:(id<MTLCommandQueue>)q
{
	self = [super init]; _queue = [q retain]; _list = [[NSMutableData alloc] init]; _keep = [[NSMutableArray alloc] init]; _completed = [[NSMutableArray alloc] init]; _scheduled = [[NSMutableArray alloc] init];
	_status = MTLCommandBufferStatusNotEnqueued; pthread_mutex_init(&_mx, NULL); pthread_cond_init(&_cv, NULL);
	return self;
}
- (void)dealloc { [_queue release]; [_list release]; [_keep release]; [_completed release]; [_scheduled release]; [_error release]; [_label release]; pthread_mutex_destroy(&_mx); pthread_cond_destroy(&_cv); [super dealloc]; }
- (void)pear_keep:(id)o { if (o) [_keep addObject:o]; }
- (id<MTLDevice>)device { return _queue.device; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (MTLCommandBufferStatus)status { pthread_mutex_lock(&_mx); MTLCommandBufferStatus s = _status; pthread_mutex_unlock(&_mx); return s; }
- (NSError *)error { return _error; }
- (id<MTLLogContainer>)logs { return nil; }
- (CFTimeInterval)kernelStartTime { return 0; }
- (CFTimeInterval)kernelEndTime { return 0; }
- (CFTimeInterval)GPUStartTime { return 0; }
- (CFTimeInterval)GPUEndTime { return 0; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoder { pmw_rec(_list, PMWC_COMPUTE_BEGIN, NULL, 0); PearMTLComputeCommandEncoder *e = [[[PearMTLComputeCommandEncoder alloc] init] autorelease]; e->_cb = self; return e; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t { return [self computeCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d { return [self computeCommandEncoder]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { pmw_rec(_list, PMWC_BLIT_BEGIN, NULL, 0); PearMTLBlitCommandEncoder *e = [[[PearMTLBlitCommandEncoder alloc] init] autorelease]; e->_cb = self; return e; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d { return [self blitCommandEncoder]; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)h { [_scheduled addObject:[[h copy] autorelease]]; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)h { [_completed addObject:[[h copy] autorelease]]; }
- (void)enqueue { pthread_mutex_lock(&_mx); if (_status < MTLCommandBufferStatusEnqueued) _status = MTLCommandBufferStatusEnqueued; pthread_mutex_unlock(&_mx); }
- (void)pear_finish:(MTLCommandBufferStatus)st error:(NSError *)err
{
	pthread_mutex_lock(&_mx); _status = st; _error = [err retain]; pthread_cond_broadcast(&_cv); pthread_mutex_unlock(&_mx);
	for (MTLCommandBufferHandler h in _completed) h(self);
	[_keep removeAllObjects];
	[self release];				/* the reference that commit took */
}
- (void)commit
{
	[self retain];
	NSMutableData *q = [NSMutableData data]; uint64_t qid = (uint64_t)(uintptr_t)_queue; [q appendBytes:&qid length:8]; [q appendData:_list];
	pthread_mutex_lock(&_mx); _status = MTLCommandBufferStatusCommitted; pthread_mutex_unlock(&_mx);
	NSData *a = nil;
	if (pmw_send(PMW_COMMIT, q.bytes, q.length, &a, nil) != 0) { [self pear_finish:MTLCommandBufferStatusError error:pmw_error(@"commit", a)]; return; }
	_sid = pmw_u64(a, 0);
	pthread_mutex_lock(&_mx); _status = MTLCommandBufferStatusScheduled; pthread_mutex_unlock(&_mx);
	for (MTLCommandBufferHandler h in _scheduled) h(self);
	pmw_send(PMW_WAIT, &_sid, 8, NULL, ^(uint32_t st, NSData *ans) {
		uint32_t code = st ? 5 : pmw_u32(ans, 0);
		NSError *err = code == 4 ? nil : [NSError errorWithDomain:@"MTLCommandBufferErrorDomain" code:1 userInfo:@{ NSLocalizedDescriptionKey: ans.length > 4 ? [[[NSString alloc] initWithBytes:(const char *)ans.bytes + 4 length:ans.length - 4 encoding:NSUTF8StringEncoding] autorelease] : @"the helper failed" }];
		[self pear_finish:(MTLCommandBufferStatus)code error:err];
	});
}
- (void)waitUntilScheduled {}
- (void)waitUntilCompleted { pthread_mutex_lock(&_mx); while (_status < MTLCommandBufferStatusCompleted) pthread_cond_wait(&_cv, &_mx); pthread_mutex_unlock(&_mx); }
- (void)presentDrawable:(id<MTLDrawable>)d { trace("presentDrawable (not yet)", NULL); }
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
@end

@implementation PearMTLCommandQueue
- (instancetype)initWithDevice:(id<MTLDevice>)d { self = [super init]; _device = d; return self; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (id<MTLCommandBuffer>)commandBuffer { return [[[PearMTLCommandBuffer alloc] initWithQueue:self] autorelease]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
@end

@implementation PearMTLDevice

- (id<MTLBuffer>)pear_makeBufferLength:(NSUInteger)len options:(MTLResourceOptions)o bytes:(const void *)b
{
	/* POSIX shared memory that the Vulkan helper maps and adopts: -contents is the memory the GPU uses (pages: what a no-copy Vulkan import wants) */
	static int n;
	PearMTLBuffer *buf = [[PearMTLBuffer alloc] init];
	size_t pg = (size_t)getpagesize(), maplen = ((len ? len : 1) + pg - 1) / pg * pg;
	char name[64]; snprintf(name, sizeof name, "/pearmtl.%d.%d", getpid(), __sync_add_and_fetch(&n, 1));
	buf->_device = self; buf->_length = len; buf->_options = o;
	int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (fd >= 0 && ftruncate(fd, (off_t)maplen) == 0) { buf->_mem = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (buf->_mem == MAP_FAILED) buf->_mem = NULL; else buf->_maplen = maplen; }
	if (fd >= 0) close(fd);
	if (!buf->_mem) { shm_unlink(name); buf->_mem = calloc(1, maplen); buf->_owned = YES; name[0] = 0; }
	if (b && len) memcpy(buf->_mem, b, len);
	NSMutableData *q = [NSMutableData data]; uint64_t l64 = maplen, o64 = o; [q appendBytes:&l64 length:8]; [q appendBytes:&o64 length:8]; [q appendBytes:name length:strlen(name) + 1];
	NSData *a = nil;
	if (pmw_send(PMW_BUFFER_NEW, q.bytes, q.length, &a, nil) == 0) { buf->_h = pmw_u64(a, 0); buf->_gpu = pmw_u64(a, 8); }
	if (name[0]) shm_unlink(name);		/* both sides have it mapped: the name is not needed any more */
	return buf;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o { trace("newBufferWithLength", NULL); return [self pear_makeBufferLength:len options:o bytes:NULL]; }
- (id<MTLBuffer>)newBufferWithBytes:(const void *)b length:(NSUInteger)len options:(MTLResourceOptions)o { trace("newBufferWithBytes", NULL); return [self pear_makeBufferLength:len options:o bytes:b]; }
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)b length:(NSUInteger)len options:(MTLResourceOptions)o deallocator:(void (^)(void *, NSUInteger))d
{
	PearMTLBuffer *buf = [[PearMTLBuffer alloc] init];
	buf->_device = self; buf->_length = len; buf->_options = o; buf->_mem = b; buf->_dealloc = [d copy];
	trace("newBufferWithBytesNoCopy", NULL);
	return buf;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	PearMTLTexture *t = [[PearMTLTexture alloc] init];
	size_t bpp = pear_bytes_per_pixel(d.pixelFormat), total = 0;
	NSUInteger w = d.width, h = d.height, dp = d.depth, layers = d.arrayLength ? d.arrayLength : 1;
	for (NSUInteger l = 0; l < (d.mipmapLevelCount ? d.mipmapLevelCount : 1); l++) { total += (w ? w : 1) * (h ? h : 1) * (dp ? dp : 1) * bpp; w >>= 1; h >>= 1; dp >>= 1; }
	total *= (d.textureType == MTLTextureTypeCube ? 6 : layers);
	t->_device = self; t->_desc = [d copy]; t->_size = total; t->_mem = calloc(1, total ? total : 1);
	trace("newTextureWithDescriptor", NULL);
	return t;
}
- (id<MTLLibrary>)pear_libraryWithBytes:(const void *)b length:(size_t)n error:(NSError **)e
{
	NSData *a = nil;
	if (pmw_send(PMW_LIBRARY_NEW, b, n, &a, nil) != 0) { if (e) *e = pmw_error(@"library", a); return nil; }
	PearMTLLibrary *l = [[PearMTLLibrary alloc] init]; l->_device = self; l->_h = pmw_u64(a, 0);
	NSMutableArray *names = [NSMutableArray array]; const char *p = (const char *)a.bytes + 8, *end = (const char *)a.bytes + a.length;
	while (p < end) { size_t k = strnlen(p, (size_t)(end - p)); if (k) [names addObject:[[[NSString alloc] initWithBytes:p length:k encoding:NSUTF8StringEncoding] autorelease]]; p += k + 1; }
	l->_names = [names copy];
	return l;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)e
{
	const void *b = NULL; size_t n = 0; dispatch_data_t flat = dispatch_data_create_map(data, &b, &n);
	id l = [self pear_libraryWithBytes:b length:n error:e]; dispatch_release(flat); return l;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)e { NSData *d = [NSData dataWithContentsOfURL:url options:0 error:e]; return d ? [self pear_libraryWithBytes:d.bytes length:d.length error:e] : nil; }
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)e { return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:e]; }
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)e { NSString *p = [bundle pathForResource:@"default" ofType:@"metallib"]; if (!p) { if (e) *e = pmw_error(@"no default.metallib", nil); return nil; } return [self newLibraryWithFile:p error:e]; }
- (id<MTLLibrary>)newDefaultLibrary { return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:NULL]; }
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)e
{
	uint64_t fh = ((PearMTLFunction *)f)->_h; NSData *a = nil;
	if (pmw_send(PMW_COMPUTE_PSO_NEW, &fh, 8, &a, nil) != 0) { if (e) *e = pmw_error(@"compute pipeline", a); return nil; }
	PearMTLComputePipelineState *p = [[PearMTLComputePipelineState alloc] init]; p->_device = self; p->_h = pmw_u64(a, 0); p->_maxThreads = pmw_u32(a, 8); p->_width = pmw_u32(a, 12); p->_staticTG = pmw_u32(a, 16);
	return p;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f options:(MTLPipelineOption)o reflection:(MTLAutoreleasedComputePipelineReflection *)r error:(NSError **)e { if (r) *r = nil; return [self newComputePipelineStateWithFunction:f error:e]; }
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLAutoreleasedComputePipelineReflection *)r error:(NSError **)e { if (r) *r = nil; return [self newComputePipelineStateWithFunction:d.computeFunction error:e]; }
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f completionHandler:(MTLNewComputePipelineStateCompletionHandler)h { NSError *e = nil; id p = [self newComputePipelineStateWithFunction:f error:&e]; h(p, e); [p release]; }
- (NSUInteger)maxThreadgroupMemoryLength { return 32768; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 64); }
- (BOOL)supportsFamily:(MTLGPUFamily)f { return f == MTLGPUFamilyCommon1 || f == MTLGPUFamilyCommon2 || f == MTLGPUFamilyMac2 || f == MTLGPUFamilyMetal3; }
- (id<MTLCommandQueue>)newCommandQueue { trace("newCommandQueue", NULL); return [[PearMTLCommandQueue alloc] initWithDevice:self]; }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n { trace("newCommandQueueWithMaxCommandBufferCount", NULL); return [[PearMTLCommandQueue alloc] initWithDevice:self]; }
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
- (instancetype)initWithAcceleratorPort:(unsigned)port { if (getenv("PEAR_METAL_MSGLOG")) instrumentObjcMessageSends(YES); _acc = port; char b[100]; snprintf(b, sizeof b, "PearMetalDriver: initWithAcceleratorPort: %u\n", port); say(b); return self; }
- (void)dealloc { say("PearMetalDriver: dealloc (the base class dealloc is not run)\n"); }
- (unsigned long)featureProfile { trace("device ", @selector(featureProfile)); return 10002; }
- (NSString *)name { trace("device ", @selector(name)); return @"Pear Software GPU"; }
- (uint64_t)registryID { trace("device ", @selector(registryID)); uint64_t rid = 0; if (getenv("PEAR_METAL_RID0")) return 0; if (_acc && IORegistryEntryGetRegistryEntryID(_acc, &rid) == 0 && rid) return rid; return 0x100000100ULL; }	/* the registry entry id of the accelerator service (what IORegistryEntryIDMatching finds again: RenderBox looks the device up by it) */
- (BOOL)isLowPower { trace("device ", @selector(isLowPower)); return NO; }
- (BOOL)isHeadless { trace("device ", @selector(isHeadless)); return YES; }
- (BOOL)isRemovable { trace("device ", @selector(isRemovable)); return NO; }
- (BOOL)hasUnifiedMemory { trace("device ", @selector(hasUnifiedMemory)); return YES; }
- (NSUInteger)registryIDHigh { trace("device ", @selector(registryIDHigh)); return 1; }
/* whatever else Metal sends that the base classes do not answer is named here (they crash on an accelerator that is not there: the next thing to implement) */
+ (BOOL)resolveInstanceMethod:(SEL)sel { trace("instance selector asked and not implemented:", sel); return [super resolveInstanceMethod:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { trace("forwardInvocation:", inv.selector); }
@end
