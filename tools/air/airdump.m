/* airdump: compiles a Metal source with the Metal of the Mac it runs on and writes the AIR bitcode of the library (the GPU VM's Metal, RgfxLibrary, has -bitcodeData: one entry per library, so a vertex and a fragment function are compiled apart and joined with llvm-link, see README).
 * clang -fobjc-arc -framework Foundation -framework Metal airdump.m -o airdump;  airdump SOURCE.metal OUT.bc */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
int main(int argc, char **argv) { @autoreleasepool {
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
  NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
  id lib = [dev newLibraryWithSource:src options:nil error:&e];
  printf("class %s\n", class_getName([lib class]));
  for (Class c = [lib class]; c; c = class_getSuperclass(c)) { unsigned n; Method *m = class_copyMethodList(c, &n); for (unsigned i = 0; i < n; i++) { const char *s = sel_getName(method_getName(m[i])); if (strcasestr(s, "data") || strcasestr(s, "serial") || strcasestr(s, "bitcode") || strcasestr(s, "air")) printf("  %s %s\n", class_getName(c), s); } free(m); }
  for (NSString *k in @[@"libraryData", @"data", @"bitcodeData"]) { @try { id v = [lib valueForKey:k]; printf("%s -> %s %lu\n", k.UTF8String, v ? class_getName([v class]) : "nil", [v respondsToSelector:@selector(length)] ? (unsigned long)[v length] : 0); if (v && argc > 2) { NSData *d = [v isKindOfClass:[NSData class]] ? v : nil; if (!d && v) { const void *b; size_t n; dispatch_data_t m = dispatch_data_create_map((dispatch_data_t)v, &b, &n); d = [NSData dataWithBytes:b length:n]; (void)m; } [d writeToFile:@(argv[2]) atomically:YES]; printf("wrote %s\n", argv[2]); break; } } @catch (id x) { printf("%s: no\n", k.UTF8String); } }
}}
