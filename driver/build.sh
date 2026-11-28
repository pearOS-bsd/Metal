#!/bin/sh
# on a Mac: sh build.sh OUTDIR  ->  OUTDIR/PearMetalDriver.bundle (x86_64 bundle; goes to /System/Library/Extensions of the image)
set -e
H="$(cd "$(dirname "$0")" && pwd)"; O="${1:-$H/out}"; B="$O/PearMetalDriver.bundle/Contents"
mkdir -p "$B/MacOS"; cp "$H/Info.plist" "$B/Info.plist"
clang -arch x86_64 -bundle -framework Foundation -framework Metal -framework IOKit -framework IOSurface -Wno-protocol -Wno-incomplete-implementation -undefined dynamic_lookup "$H/PearMetalDriver.m" -o "$B/MacOS/PearMetalDriver"
