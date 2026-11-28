/* pmw.h: the wire of PearMetalDriver (BSD-2-Clause, this repository) and the Vulkan helper (pearOS-bsd/metal2vulkan, GPL, its own process).
 * The helper is reached only through this protocol: a stream socket (PMW_SOCKET), little endian, every message a header and a body.
 * Requests are answered in order with a reply of the same seq (status 0 = done; else an error text as the body).  The command list of a
 * command buffer is recorded in the driver and travels whole at commit (PMW_COMMIT); its completion comes back as the reply of PMW_WAIT.
 * Memory that both sides use (buffers, linear textures) is POSIX shared memory made by the driver (shm_open name in the request):
 * the helper maps the same object and adopts it as host memory, so -contents of a buffer is the memory the GPU reads and writes.
 * Documentation: docs/HELPER-PROTOCOL.md. */
#ifndef PMW_H
#define PMW_H
#include <stdint.h>

#define PMW_SOCKET	"/var/run/pear-metal.sock"
#define PMW_VERSION	1

typedef struct { uint32_t op, len; uint64_t seq; } pmw_hdr;	/* len: bytes of the body after the header */
typedef struct { uint32_t status, len; uint64_t seq; } pmw_rep;	/* reply: status 0, then len bytes of answer */

enum pmw_op {
	PMW_HELLO = 1,		/* u32 version -> u32 version, u64 registry id, u32 flags, name (NUL-terminated) */
	PMW_RELEASE = 2,	/* u64 handle -> nothing */
	PMW_BUFFER_NEW = 10,	/* u64 length, u64 options (MTLResourceOptions), shm name (NUL-terminated, empty: private memory) -> u64 handle, u64 gpu address */
	PMW_TEXTURE_NEW = 11,	/* pmw_texture_desc, shm name (empty: the helper owns the memory) -> u64 handle */
	PMW_TEXTURE_REPLACE = 12, /* u64 tex, pmw_region, u32 level, u32 slice, u64 bytesPerRow, u64 bytesPerImage, the bytes -> nothing */
	PMW_TEXTURE_GET = 13,	/* u64 tex, pmw_region, u32 level, u32 slice, u64 bytesPerRow, u64 bytesPerImage -> the bytes */
	PMW_LIBRARY_NEW = 20,	/* the metallib (or AIR bitcode) bytes -> u64 handle, then the function names (NUL-separated) */
	PMW_FUNCTION_NEW = 21,	/* u64 library, name (NUL-terminated) -> u64 handle, u32 function type (MTLFunctionType) */
	PMW_COMPUTE_PSO_NEW = 30, /* u64 function -> u64 handle, u32 maxTotalThreadsPerThreadgroup, u32 threadExecutionWidth, u32 static threadgroup memory */
	PMW_RENDER_PSO_NEW = 31,  /* pmw_render_desc -> u64 handle */
	PMW_SAMPLER_NEW = 32,	/* pmw_sampler_desc -> u64 handle */
	PMW_COMMIT = 40,	/* u64 queue id (the driver's), the command list (pmw_cmd records) -> u64 submission id */
	PMW_WAIT = 41,		/* u64 submission id -> u32 MTLCommandBufferStatus, error text */
};

/* the command list of PMW_COMMIT: records of u16 code, u16 size (bytes of the record, header included), the arguments */
enum pmw_cmd_code {
	PMWC_COMPUTE_BEGIN = 1,	/* nothing */
	PMWC_RENDER_BEGIN = 2,	/* pmw_render_pass */
	PMWC_BLIT_BEGIN = 3,
	PMWC_END = 4,		/* end of the encoder */
	PMWC_SET_COMPUTE_PSO = 10,	/* u64 pso */
	PMWC_SET_BUFFER = 11,	/* u32 stage (0 compute, 1 vertex, 2 fragment), u32 index, u64 buffer, u64 offset */
	PMWC_SET_BYTES = 12,	/* u32 stage, u32 index, the bytes */
	PMWC_SET_TEXTURE = 13,	/* u32 stage, u32 index, u64 texture */
	PMWC_SET_SAMPLER = 14,	/* u32 stage, u32 index, u64 sampler */
	PMWC_SET_TG_MEMORY = 15,	/* u32 index, u32 length */
	PMWC_DISPATCH_THREADS = 20,	/* u64 grid w h d, u64 threadgroup w h d */
	PMWC_DISPATCH_TGROUPS = 21,	/* u64 threadgroups w h d, u64 threadgroup w h d */
	PMWC_SET_RENDER_PSO = 30,	/* u64 pso */
	PMWC_SET_VIEWPORT = 31,	/* 6 doubles */
	PMWC_SET_SCISSOR = 32,	/* 4 u64 */
	PMWC_DRAW = 33,		/* u32 primitive, u32 pad, u64 vertexStart, u64 vertexCount, u64 instanceCount, u64 baseInstance */
	PMWC_DRAW_INDEXED = 34,	/* u32 primitive, u32 indexType, u64 indexCount, u64 indexBuffer, u64 indexOffset, u64 instanceCount, i64 baseVertex, u64 baseInstance */
	PMWC_COPY_BUF = 40,	/* u64 src, u64 srcOffset, u64 dst, u64 dstOffset, u64 size */
	PMWC_FILL_BUF = 41,	/* u64 buf, u64 offset, u64 length, u32 value byte */
};

typedef struct { uint64_t x, y, z, w, h, d; } pmw_region;
typedef struct { uint32_t type, format, usage, storage; uint64_t width, height, depth, mipmaps, samples, arrayLength, options; } pmw_texture_desc;
#endif
