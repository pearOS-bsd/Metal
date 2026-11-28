# The Vulkan helper protocol (PearMetalDriver <-> pear-metal-helper)

pearOS' Metal is Apple's `Metal.framework` (from the dyld cache) with our driver bundle `PearMetalDriver` (this repository, BSD-2-Clause), loaded by Metal through the `IOAccelerator` node of darwinator's registry.  The GPU work is done by **pear-metal-helper**, a native FreeBSD program in `pearOS-bsd/metal2vulkan` (GPL-2.0-or-later, the Metal API of `metal2vulkan-runtime` on a Vulkan device: lavapipe in the VM, a real GPU later).  The two meet only here, through a socket: no GPL code is linked into a BSD repository (owner decision 2026-11-22).

```
Mac program -> Metal.framework (Apple) -> PearMetalDriver (MTLDevice, MTLBuffer, MTLCommandBuffer ... in the process)
                                              | stream socket /var/run/pear-metal.sock (PEAR_METAL_SOCKET), pmw.h
                                              v
                                  pear-metal-helper (FreeBSD, Rust) -> metal2vulkan-runtime -> Vulkan
```

## Messages
`driver/pmw.h` is the definition.  Every message is a 16-byte header (`op`, `len`, `seq`) and `len` bytes; every request gets a reply with the same `seq` (`status` 0 and an answer, or an error text).  Requests are answered in order, except `PMW_WAIT`, which the helper answers from a thread of its own when the GPU is done (the driver's reader thread hands each reply to its request by `seq`, so a wait does not hold the connection).

| request | body | answer |
|---|---|---|
| HELLO | u32 version | u32 version, u64 registry id, u32 flags, device name |
| BUFFER_NEW | u64 length (pages), u64 MTLResourceOptions, shm name | u64 handle, u64 GPU address |
| LIBRARY_NEW | metallib / AIR bytes | u64 handle, function names |
| FUNCTION_NEW | u64 library, name | u64 handle, u32 MTLFunctionType |
| COMPUTE_PSO_NEW | u64 function | u64 handle, max threads per threadgroup, execution width, static threadgroup memory |
| COMMIT | u64 queue id, the command list | u64 submission id |
| WAIT | u64 submission id | u32 MTLCommandBufferStatus, error text |
| RELEASE | u64 handle | - |

The command list of a commit is a sequence of records (`u16 code, u16 size, arguments`): encoder begin / end, set pipeline / buffer / bytes / threadgroup memory, dispatches, buffer copies and fills (render passes, textures and samplers are the next records).

## Memory
A buffer is POSIX shared memory: the driver `shm_open`s a fresh name, sizes it to whole pages, maps it (that mapping is `-contents`), sends the name, the helper maps the same object and adopts it with `new_buffer_with_bytes_no_copy` (Vulkan external host memory), then the driver unlinks the name.  CPU writes before a commit and GPU writes after a completed command buffer are therefore seen by both sides without a copy.  darwinator passes `shm_open` of a Mac program to FreeBSD's `shm_open2`, so both processes name the same object.

## Status
2026-11-28: the compute path (buffers, libraries, functions, compute pipelines, compute and blit encoders, commit, completion handlers, waitUntilCompleted) in the driver and the helper; render passes, textures, samplers, IOSurface-backed textures (WindowServer, CoreAnimation, RenderBox) next.
