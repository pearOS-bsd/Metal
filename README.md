# Metal

Metal.framework for pearOS BSD: the Metal API (`MTLDevice`, `MTLCommandQueue`, buffers, textures, render / compute / blit encoders, events, libraries) implemented over Vulkan, with the same Objective-C ABI as Apple's `Metal.framework` (install name `/System/Library/Frameworks/Metal.framework/Versions/A/Metal`).

**Layer 2 (core frameworks).** Why: Apple's `RenderBox` (SwiftUI's renderer), CoreImage, QuartzCore's glass effects and every Metal application draw through it. See the `SwiftUI` repository.

Status: planned, nothing implemented yet.

## Plan
1. Surface first: `docs/API-SURFACE.md` lists every `MTL*` symbol and protocol selector that real RenderBox, SwiftUICore, QuartzCore and CoreImage import (read with REA from the cache, never committed), ordered by use.
2. `MTLCreateSystemDefaultDevice` + queue + buffer + texture + render pass over Vulkan (Mesa lavapipe in the VM, virgl / real GPU later); `IOSurface`-backed textures.
3. Shaders: Apple's `.metallib` is AIR (LLVM bitcode). A translator AIR to SPIR-V of our own (LLVM's SPIR-V backend is Apache-2.0 and may be used; `steelbrain/metal2vulkan` is GPL/LGPL and stays a measuring tool only, nothing copied). Test bed: the 180 functions of QuartzCore's `default.metallib` (see `Solarium/docs/METAL-SHADERS.md`: 18/18 glass shaders already translate).
4. Compare against the real Metal on the Mac (differential tests, same pattern as QuartzCore).
5. MetalKit, MetalPerformanceShaders later.

## Rules
Apple files are never committed (metallibs come from the owner's Mac). BSD-2-Clause for our code. Search `scripts/where-is.sh` and the code index before adding anything.

## Findings of 2026-11-20 (first contact with the real Metal.framework on pearOS)
Evidence and the run that led here: `SwiftUI/docs/EVIDENCE.md`.
* The real SwiftUI app (Calculator) on the real dyld + cache reaches Metal and stops there: `-[MTLIOAccelServiceGlobalContext init]: IOServiceAddMatchingNotification failed e00002c7` (kIOReturnUnsupported), repeated by several threads; no window. The generic part of Apple's Metal looks for `IOAccelerator` services in IOKit and loads the GPU driver plug-in they name; there is no such service, so there is no `MTLDevice`.
* Consequence for the design: faking the IOKit accelerator for the real Metal would mean reimplementing the kernel's IOAccelerator user-client ABI and a closed driver's command stream. The plan stays: **our own Metal.framework** (an `MTLDevice` implementation over Vulkan) that takes the place of Apple's in the process. Open problem: how it takes the place of the copy in the dyld cache, which RenderBox and QuartzCore are already bound to.
  * `DYLD_INSERT_LIBRARIES`: the real dyld then stops using the shared cache for the program (Foundation "slice is not valid mach-o"): not usable.
  * A normal extra dependency (`tools/trace-device/add-dylib.py` adds an `LC_LOAD_DYLIB`) is loaded fine (an empty C library: Calculator runs as before). `__DATA,__interpose` tuples for `MTLCreateSystemDefaultDevice`, `MTLCopyAllDevices` and `IOServiceAddMatchingNotification` were **never called** (no log) although the failing init runs: either the calls are not made through the exported symbols, or interposing does not reach those cache images in this dyld setup. To find out first: interpose a symbol that is certainly called (`getpid`) from the same kind of library, then read who calls `MTLIOAccelServiceGlobalContext init` (backtrace of the thread, as in `SwiftUI/docs/EVIDENCE.md`).
  * An ObjC library built with `-fobjc-arc` on the Mac VM (`tools/trace-device/mtltrace.m`) as an extra dependency crashes the process in `objc_autoreleasePoolPop` on a workqueue thread (also seen in `lsd-objc`): a darwinator / workqueue problem to look at before ObjC code of ours runs inside a SwiftUI process.
* `tools/trace-device`: `mtltrace.m` (a device object that logs every selector sent to it) and `add-dylib.py`; written, **not yet shown to work**.
