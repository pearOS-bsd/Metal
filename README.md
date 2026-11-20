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
