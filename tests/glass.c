/* glass: a native FreeBSD program that draws QuartzCore's own glass shader (sdf_filter_vert_lpf + glass_background_sdf_lpf of QuartzCore's
 * default.metallib) over a backdrop through pear-metal-helper (client/pmwc), and writes the result as a PPM.  What the window server will do for a
 * glassBackground filter.  The uniforms here are placeholders until GlassBackgroundFilter::render is decompiled (docs in Solarium/docs/CONTROLCENTER-GLASS.md).
 *   cc -I.. glass.c ../client/pmwc.c -lm -o glass;  glass QUARTZCORE.metallib OUT.ppm */
#include "../client/pmwc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

enum { W = 400, H = 300, GW = 260, GH = 120 };

static uint16_t half(float f)		/* IEEE half from float (normal range) */
{
	uint32_t x; memcpy(&x, &f, 4);
	uint32_t s = (x >> 16) & 0x8000, e = ((x >> 23) & 0xff), m = x & 0x7fffff;
	if (e == 0) return (uint16_t)s;
	int ne = (int)e - 127 + 15;
	if (ne <= 0) return (uint16_t)s;
	if (ne >= 31) return (uint16_t)(s | 0x7c00);
	return (uint16_t)(s | (ne << 10) | (m >> 13));
}

int main(int argc, char **argv)
{
	if (argc < 3) return 2;
	if (pmwc_connect(NULL) != 0) { printf("glass: no helper\n"); return 1; }
	uint64_t lib = pmwc_library_file(argv[1]);
	uint64_t vf = lib ? pmwc_function(lib, "sdf_filter_vert_lpf") : 0, ff = lib ? pmwc_function(lib, "glass_background_sdf_lpf") : 0;
	printf("glass: library %s, functions %s %s\n", lib ? "ok" : "FAILED", vf ? "vertex" : "-", ff ? "fragment" : "-");
	if (!vf || !ff) return 1;

	/* the render pipeline: BGRA8, the vertex descriptor of sdf_filter_vert (position float4 @0, sdf_uv float2 @16, src_uv float2 @24, stride 32, buffer 0) */
	uint8_t q[sizeof(pmw_render_desc) + 4 + 3 * 16 + 4 + 16]; memset(q, 0, sizeof q);
	pmw_render_desc *rd = (pmw_render_desc *)q;
	rd->vertex_fn = vf; rd->fragment_fn = ff; rd->samples = 1;
	rd->color[0] = (pmw_blend){ 80 /* BGRA8Unorm */, 0, 1, 0, 0, 1, 0, 0, 0xf };
	uint32_t *w = (uint32_t *)(q + sizeof *rd);
	w[0] = 3;
	w[1] = 0; w[2] = 31 /* float4 */; w[3] = 0;  w[4] = 0;
	w[5] = 1; w[6] = 29 /* float2 */; w[7] = 16; w[8] = 0;
	w[9] = 2; w[10] = 29;             w[11] = 24; w[12] = 0;
	w[13] = 1; w[14] = 0; w[15] = 32; w[16] = 1 /* per vertex */; w[17] = 1;
	uint8_t *a; uint32_t n;
	int st = pmwc_call(PMW_RENDER_PSO_NEW, q, sizeof q, &a, &n);
	uint64_t pso = 0; if (st == 0 && n >= 8) memcpy(&pso, a, 8); else printf("glass: pipeline: %.*s\n", (int)n, a);
	free(a);
	if (!pso) return 1;

	/* the backdrop: diagonal colour bands and dark lines (something whose refraction shows) */
	pmw_texture_desc td = { 2 /* 2D */, 80, 1 | 4 /* ShaderRead | RenderTarget */, 0, W, H, 1, 1, 1, 1, 0 };
	uint64_t src = pmwc_texture(&td), dst = pmwc_texture(&td);
	uint8_t *px = malloc(W * H * 4);
	for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
		uint8_t *p = px + (y * W + x) * 4; float t = (x + y) * 0.02f;
		p[2] = (uint8_t)(127 + 127 * sinf(t)); p[1] = (uint8_t)(127 + 127 * sinf(t + 2.1f)); p[0] = (uint8_t)(127 + 127 * sinf(t + 4.2f)); p[3] = 255;
		if ((x / 20 + y / 20) % 2 == 0 && (x % 20 < 2 || y % 20 < 2)) p[0] = p[1] = p[2] = 20;
	}
	pmwc_texture_replace(src, W, H, px, W * 4);

	/* a quad over the glass rectangle: clip-space position, sdf_uv in points from the centre, src_uv in the backdrop */
	float x0 = (W - GW) / 2.0f, y0 = (H - GH) / 2.0f, x1 = x0 + GW, y1 = y0 + GH;
	float vx[6][8]; float cx[6] = { x0, x1, x0, x1, x1, x0 }, cy[6] = { y0, y0, y1, y0, y1, y1 };
	for (int i = 0; i < 6; i++) { vx[i][0] = cx[i] / W * 2 - 1; vx[i][1] = 1 - cy[i] / H * 2; vx[i][2] = 0; vx[i][3] = 1;
		vx[i][4] = cx[i] - W / 2.0f; vx[i][5] = cy[i] - H / 2.0f; vx[i][6] = cx[i] / W; vx[i][7] = cy[i] / H; }
	float mvp[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 }, texmat[4] = { 1, 1, 0, 0 };

	/* the uniforms (placeholders): SdfFragmentUniforms (arg: half size, mode 0 = box, normal mix; tr: 2x2; arg2), GlassBackgroundUniforms (Control Center's values) */
	uint8_t u[320]; memset(u, 0, sizeof u);
	float sdf[12] = { GW / 2.0f, GH / 2.0f, 0, 0,  1, 0, 0, 1,  0, 0, 0, 0 };
	memcpy(u, sdf, sizeof sdf);
	uint8_t *g = u + 48;
	float dm[4] = { 1, 0, 0, 1 }; memcpy(g, dm, 16);
	float f16[] = { -80, 1 / 20.0f, 10, 1 / 5.0f, 0, 1, 4, 0, 0, 0, 0, 0 }; memcpy(g + 16, f16, sizeof f16);
	uint16_t cm[12] = { half(1), half(0), half(0), half(0),  half(0), half(1), half(0), half(0),  half(0), half(0), half(1), half(0) };
	memcpy(g + 80, cm, 24); memcpy(g + 104, cm, 24); memcpy(g + 128, cm, 24);
	float op = 1; memcpy(g + 204, &op, 4); float ro = 0.1525f; memcpy(g + 224, &ro, 4); float cl = 1; memcpy(g + 240, &cl, 4);
	float edr = 1;

	pmwc_list l = { 0 };
	pmw_render_pass rp; memset(&rp, 0, sizeof rp);
	rp.color[0].tex = dst; rp.color[0].load = 1 /* load */; rp.color[0].store = 1;
	/* first the backdrop copied into the target (the glass draws over it) */
	pmwc_list c = { 0 };
	{ uint64_t cp[14] = { src, 0, 0, 0, 0, 0, W, H, 1, dst, 0, 0, 0, 0 }; (void)cp; }
	if (getenv("GLASS_BLACK")) { uint8_t *z = calloc(W * H, 4); pmwc_texture_replace(dst, W, H, z, W * 4); free(z); }	/* GLASS_BLACK=1: the target starts black: shows where the shader draws */
	else pmwc_texture_replace(dst, W, H, px, W * 4);
	pmwc_cmd(&l, PMWC_RENDER_BEGIN, &rp, sizeof rp);
	pmwc_cmd(&l, PMWC_SET_RENDER_PSO, &pso, 8);
	{ uint8_t b[8 + sizeof vx]; uint32_t s2[2] = { 1, 0 }; memcpy(b, s2, 8); memcpy(b + 8, vx, sizeof vx); pmwc_cmd(&l, PMWC_SET_BYTES, b, sizeof b); }
	{ uint8_t b[8 + 64]; uint32_t s2[2] = { 1, 2 }; memcpy(b, s2, 8); memcpy(b + 8, mvp, 64); pmwc_cmd(&l, PMWC_SET_BYTES, b, sizeof b); }
	{ uint8_t b[8 + 16]; uint32_t s2[2] = { 1, 3 }; memcpy(b, s2, 8); memcpy(b + 8, texmat, 16); pmwc_cmd(&l, PMWC_SET_BYTES, b, sizeof b); }
	{ uint8_t b[8 + 320]; uint32_t s2[2] = { 2, 1 }; memcpy(b, s2, 8); memcpy(b + 8, u, 320); pmwc_cmd(&l, PMWC_SET_BYTES, b, sizeof b); }
	{ uint8_t b[8 + 4]; uint32_t s2[2] = { 2, 6 }; memcpy(b, s2, 8); memcpy(b + 8, &edr, 4); pmwc_cmd(&l, PMWC_SET_BYTES, b, sizeof b); }
	{ uint8_t b[16]; uint32_t s2[2] = { 2, 3 }; memcpy(b, s2, 8); memcpy(b + 8, &src, 8); pmwc_cmd(&l, PMWC_SET_TEXTURE, b, sizeof b); }
	{ uint64_t dr[5]; uint32_t pr[2] = { 3 /* triangle */, 0 }; memcpy(dr, pr, 8); dr[1] = 0; dr[2] = 6; dr[3] = 1; dr[4] = 0; pmwc_cmd(&l, PMWC_DRAW, dr, sizeof dr); }
	pmwc_cmd(&l, PMWC_END, NULL, 0);
	(void)c;
	int ok = pmwc_commit_wait(&l);
	pmwc_texture_get(dst, W, H, px, W * 4);
	printf("glass: render %s\n", ok == 0 ? "completed" : "FAILED");
	FILE *f = fopen(argv[2], "wb"); fprintf(f, "P6\n%d %d\n255\n", W, H);
	for (int i = 0; i < W * H; i++) { fputc(px[i * 4 + 2], f); fputc(px[i * 4 + 1], f); fputc(px[i * 4], f); }
	fclose(f);
	return ok;
}
