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

static void say(const char *s) { write(2, s, strlen(s)); }
static void trace(const char *what, SEL sel) { char b[240]; snprintf(b, sizeof b, "PearMetalDriver: %s %s\n", what, sel ? sel_getName(sel) : ""); say(b); }

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
{ @public id<MTLDevice> _device; NSString *_label; void *_mem; NSUInteger _length; MTLResourceOptions _options; BOOL _owned; void (^_dealloc)(void *, NSUInteger); }
@end

@implementation PearMTLBuffer
- (void)dealloc
{
	if (_dealloc) _dealloc(_mem, _length); else if (_owned) free(_mem);
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
- (uint64_t)gpuAddress { return (uint64_t)(uintptr_t)_mem; }
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

@implementation PearMTLCommandQueue
- (instancetype)initWithDevice:(id<MTLDevice>)d { self = [super init]; _device = d; return self; }
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label release]; _label = [l copy]; }
- (id<MTLCommandBuffer>)commandBuffer { trace("queue commandBuffer", NULL); return nil; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { trace("queue commandBufferWithDescriptor", NULL); return nil; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { trace("queue commandBufferWithUnretainedReferences", NULL); return nil; }
- (void)insertDebugCaptureBoundary {}
@end

@implementation PearMTLDevice

- (id<MTLBuffer>)pear_makeBufferLength:(NSUInteger)len options:(MTLResourceOptions)o bytes:(const void *)b
{
	PearMTLBuffer *buf = [[PearMTLBuffer alloc] init];
	buf->_device = self; buf->_length = len; buf->_options = o; buf->_owned = YES;
	buf->_mem = calloc(1, len ? len : 1);
	if (b && len) memcpy(buf->_mem, b, len);
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
- (instancetype)initWithAcceleratorPort:(unsigned)port { _acc = port; char b[100]; snprintf(b, sizeof b, "PearMetalDriver: initWithAcceleratorPort: %u\n", port); say(b); return self; }
- (void)dealloc { say("PearMetalDriver: dealloc (the base class dealloc is not run)\n"); }
- (unsigned long)featureProfile { trace("device ", @selector(featureProfile)); return 10002; }
- (NSString *)name { trace("device ", @selector(name)); return @"Pear Software GPU"; }
- (uint64_t)registryID { trace("device ", @selector(registryID)); uint64_t rid = 0; if (_acc && IORegistryEntryGetRegistryEntryID(_acc, &rid) == 0 && rid) return rid; return 0x100000100ULL; }	/* the registry entry id of the accelerator service (what IORegistryEntryIDMatching finds again: RenderBox looks the device up by it) */
- (BOOL)isLowPower { trace("device ", @selector(isLowPower)); return NO; }
- (BOOL)isHeadless { trace("device ", @selector(isHeadless)); return YES; }
- (BOOL)isRemovable { trace("device ", @selector(isRemovable)); return NO; }
- (BOOL)hasUnifiedMemory { trace("device ", @selector(hasUnifiedMemory)); return YES; }
- (NSUInteger)registryIDHigh { trace("device ", @selector(registryIDHigh)); return 1; }
/* whatever else Metal sends that the base classes do not answer is named here (they crash on an accelerator that is not there: the next thing to implement) */
+ (BOOL)resolveInstanceMethod:(SEL)sel { trace("instance selector asked and not implemented:", sel); return [super resolveInstanceMethod:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { trace("forwardInvocation:", inv.selector); }
@end
