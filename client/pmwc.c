/* pmwc: see pmwc.h.  BSD-2-Clause. */
#include "pmwc.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

static int fd = -1;
static uint64_t seq;

int pmwc_connect(const char *path)
{
	struct sockaddr_un sa;

	if (fd >= 0) return 0;
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	strncpy(sa.sun_path, path ? path : PMW_SOCKET, sizeof sa.sun_path - 1);
	if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); fd = -1; return -1; }
	uint32_t v = PMW_VERSION; uint8_t *a = NULL; uint32_t n = 0;
	int st = pmwc_call(PMW_HELLO, &v, 4, &a, &n);
	free(a);
	return st == 0 ? 0 : -1;
}

static int io(void *p, size_t n, int wr)
{
	size_t d = 0;
	while (d < n) {
		ssize_t k = wr ? write(fd, (char *)p + d, n - d) : read(fd, (char *)p + d, n - d);
		if (k <= 0) { close(fd); fd = -1; return -1; }
		d += (size_t)k;
	}
	return 0;
}

int pmwc_call(uint32_t op, const void *body, uint32_t len, uint8_t **ans, uint32_t *alen)
{
	pmw_hdr h = { op, len, ++seq };
	pmw_rep r;

	if (ans) *ans = NULL;
	if (alen) *alen = 0;
	if (fd < 0 && pmwc_connect(NULL) != 0) return -1;
	if (io(&h, sizeof h, 1) || (len && io((void *)body, len, 1))) return -1;
	for (;;) {
		if (io(&r, sizeof r, 0)) return -1;
		uint8_t *b = malloc(r.len ? r.len : 1);
		if (!b || (r.len && io(b, r.len, 0))) { free(b); return -1; }
		if (r.seq != h.seq) { free(b); continue; }		/* not ours (cannot happen with one request at a time) */
		if (ans) *ans = b; else free(b);
		if (alen) *alen = r.len;
		return (int)r.status;
	}
}

static uint64_t u64_of(int st, uint8_t *a, uint32_t n)
{
	uint64_t v = 0;
	if (st == 0 && n >= 8) memcpy(&v, a, 8);
	free(a);
	return v;
}

uint64_t pmwc_library_file(const char *path)
{
	uint8_t *a; uint32_t n;
	return u64_of(pmwc_call(PMW_LIBRARY_FILE, path, (uint32_t)strlen(path) + 1, &a, &n), a, n);
}

uint64_t pmwc_function(uint64_t lib, const char *name)
{
	size_t k = strlen(name);
	uint8_t *q = malloc(8 + k + 1), *a; uint32_t n;
	memcpy(q, &lib, 8); memcpy(q + 8, name, k + 1);
	int st = pmwc_call(PMW_FUNCTION_NEW, q, (uint32_t)(8 + k + 1), &a, &n);
	free(q);
	return u64_of(st, a, n);
}

uint64_t pmwc_texture(const pmw_texture_desc *d)
{
	uint8_t q[sizeof *d + 1], *a; uint32_t n;
	memcpy(q, d, sizeof *d); q[sizeof *d] = 0;
	return u64_of(pmwc_call(PMW_TEXTURE_NEW, q, sizeof q, &a, &n), a, n);
}

static int tex_io(uint32_t op, uint64_t tex, uint32_t w, uint32_t h, void *bytes, uint64_t bpr)
{
	size_t sz = (size_t)bpr * h, hd = 8 + sizeof(pmw_region) + 8 + 16;
	uint8_t *q = malloc(hd + (op == PMW_TEXTURE_REPLACE ? sz : 0)), *a; uint32_t n;
	pmw_region rg = { 0, 0, 0, w, h, 1 };
	uint32_t ls[2] = { 0, 0 }; uint64_t bb[2] = { bpr, 0 };
	memcpy(q, &tex, 8); memcpy(q + 8, &rg, sizeof rg); memcpy(q + 8 + sizeof rg, ls, 8); memcpy(q + 16 + sizeof rg, bb, 16);
	if (op == PMW_TEXTURE_REPLACE) memcpy(q + hd, bytes, sz);
	int st = pmwc_call(op, q, (uint32_t)(hd + (op == PMW_TEXTURE_REPLACE ? sz : 0)), &a, &n);
	free(q);
	if (st == 0 && op == PMW_TEXTURE_GET) memcpy(bytes, a, n < sz ? n : sz);
	free(a);
	return st;
}
int pmwc_texture_replace(uint64_t tex, uint32_t w, uint32_t h, const void *bytes, uint64_t bpr) { return tex_io(PMW_TEXTURE_REPLACE, tex, w, h, (void *)bytes, bpr); }
int pmwc_texture_get(uint64_t tex, uint32_t w, uint32_t h, void *bytes, uint64_t bpr) { return tex_io(PMW_TEXTURE_GET, tex, w, h, bytes, bpr); }

void pmwc_release(uint64_t h) { if (h) pmwc_call(PMW_RELEASE, &h, 8, NULL, NULL); }

void pmwc_cmd(pmwc_list *l, uint16_t code, const void *args, uint16_t len)
{
	uint16_t hd[2] = { code, (uint16_t)(4 + len) };
	if (l->n + 4 + len > l->cap) { l->cap = (l->cap + 4 + len) * 2; l->b = realloc(l->b, l->cap); }
	memcpy(l->b + l->n, hd, 4); if (len) memcpy(l->b + l->n + 4, args, len); l->n += 4 + len;
}

int pmwc_commit_wait(pmwc_list *l)
{
	uint8_t *q = malloc(8 + l->n), *a; uint32_t n; uint64_t qid = 1, sid;
	memcpy(q, &qid, 8); memcpy(q + 8, l->b, l->n);
	int st = pmwc_call(PMW_COMMIT, q, (uint32_t)(8 + l->n), &a, &n);
	free(q);
	if ((sid = u64_of(st, a, n)) == 0) return -1;
	st = pmwc_call(PMW_WAIT, &sid, 8, &a, &n);
	uint32_t code = 0; if (st == 0 && n >= 4) memcpy(&code, a, 4);
	free(a);
	return st == 0 && code == 4 ? 0 : -1;
}
