#!/usr/bin/env python3
"""add-dylib.py IN OUT /path/lib.dylib: a copy of the thin x86_64 Mach-O IN with one more LC_LOAD_DYLIB (written into the slack after the load commands).
DYLD_INSERT_LIBRARIES makes the real dyld stop using the shared cache for the program (Foundation is then not found on disk), a normal dependency does not; the __interpose
tuples of a dependency apply to the whole process, also to the images of the cache."""
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read()); lib = sys.argv[3].encode() + b'\0'
m, = struct.unpack_from('<I', d, 0)
if m in (0xbebafeca,):                                  # fat (cafebabe read little endian): take the x86_64 slice
    n, = struct.unpack_from('>I', d, 4)
    for i in range(n):
        cpu, sub, off, size, al = struct.unpack_from('>IIIII', d, 8 + 20 * i)
        if cpu == 0x01000007: d = bytearray(d[off:off + size]); break
assert struct.unpack_from('<I', d, 0)[0] == 0xfeedfacf and struct.unpack_from('<I', d, 4)[0] == 0x01000007, 'need a thin x86_64 Mach-O'
ncmds, sizeofcmds = struct.unpack_from('<II', d, 16)
off, first = 32, 1 << 62
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd == 0x19:                                      # LC_SEGMENT_64: smallest file offset of a section = end of the slack
        nsects, = struct.unpack_from('<I', d, off + 64)
        for s in range(nsects):
            so = off + 72 + 80 * s; foff, = struct.unpack_from('<I', d, so + 48)
            if foff: first = min(first, foff)
    off += size
cmdsize = (24 + len(lib) + 7) & ~7
assert 32 + sizeofcmds + cmdsize <= first, 'no room in the header (%d free, %d needed)' % (first - 32 - sizeofcmds, cmdsize)
at = 32 + sizeofcmds
d[at:at + cmdsize] = struct.pack('<IIIIII', 0xc, cmdsize, 24, 2, 0x10000, 0x10000) + lib + b'\0' * (cmdsize - 24 - len(lib))
struct.pack_into('<II', d, 16, ncmds + 1, sizeofcmds + cmdsize)
open(sys.argv[2], 'wb').write(d)
