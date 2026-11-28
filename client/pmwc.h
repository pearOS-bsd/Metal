/* pmwc: a C client of the pear-metal-helper protocol (driver/pmw.h) for native programs of the system (the window server draws QuartzCore's glass with
 * QuartzCore's own shaders through it).  BSD-2-Clause.  Synchronous: one request at a time, from one thread. */
#ifndef PMWC_H
#define PMWC_H
#include <stdint.h>
#include <stddef.h>
#include "../driver/pmw.h"

int pmwc_connect(const char *path);	/* NULL: PMW_SOCKET; 0 or -1 */
/* a request and its answer (malloc'd, *alen bytes; free it): 0 done, else the helper's status (the answer is its error text) or -1 (the connection) */
int pmwc_call(uint32_t op, const void *body, uint32_t len, uint8_t **ans, uint32_t *alen);
uint64_t pmwc_library_file(const char *path);			/* 0: failed */
uint64_t pmwc_function(uint64_t lib, const char *name);
uint64_t pmwc_texture(const pmw_texture_desc *d);
int pmwc_texture_replace(uint64_t tex, uint32_t w, uint32_t h, const void *bytes, uint64_t bytes_per_row);
int pmwc_texture_get(uint64_t tex, uint32_t w, uint32_t h, void *bytes, uint64_t bytes_per_row);
void pmwc_release(uint64_t h);

/* a command list (pmw_cmd records) */
typedef struct { uint8_t *b; size_t n, cap; } pmwc_list;
void pmwc_cmd(pmwc_list *l, uint16_t code, const void *args, uint16_t len);
int pmwc_commit_wait(pmwc_list *l);	/* commit on queue 1 and wait: 0 when the command buffer completed */
#endif
