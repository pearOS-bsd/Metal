#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
vertex V art_vertex(uint vid [[vertex_id]])
{
	float2 p = float2((vid << 1) & 2, vid & 2);	/* one triangle that covers the screen */
	V v; v.pos = float4(p * 2.0 - 1.0, 0, 1); v.uv = float2(p.x, 1.0 - p.y); return v;
}
