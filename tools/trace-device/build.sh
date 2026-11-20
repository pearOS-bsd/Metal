#!/bin/sh
# on a Mac (Xcode command line tools): sh build.sh  ->  libmtltrace.dylib (x86_64 and the machine's own architecture)
cd "$(dirname "$0")" && clang -fobjc-arc -dynamiclib -framework Foundation -framework Metal mtltrace.m -o libmtltrace.dylib
