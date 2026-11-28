# AIR for the tests (without Xcode)

The Command Line Tools have no `metal` compiler.  The tests get their AIR from the Metal of the GPU Mac VM:
`airdump SOURCE.metal OUT.bc` writes the bitcode of the compiled library (its `-bitcodeData`).  That Metal keeps one entry
per library, so a render test compiles its vertex and fragment functions from two sources and joins them on the FreeBSD VM:

```
llvm-link vertex.bc fragment.bc -o both.bc
llvm-dis both.bc -o both.ll     # keep one of each of !llvm.ident, !air.version, !air.language_version, !air.compile_options (llvm-link repeats them; the AIR reader refuses repeats)
llvm-as both.ll -o render.metallib
```

The helper takes AIR bitcode as well as a metallib container (`PMW_LIBRARY_NEW`).  Results of 2026-11-28 on pearOS (lab VM,
lavapipe): `tests/compute` (1000 floats, `out[i] = 2 in[i] + i`) and `tests/render` (8x8 texture: cleared blue, a quarter drawn
orange, every texel checked) pass through Apple's Metal.framework, PearMetalDriver, pear-metal-helper and Vulkan.
