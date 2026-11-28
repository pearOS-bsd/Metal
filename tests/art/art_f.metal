#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
static float3 rainbow(float t) { return 0.5 + 0.5 * cos(6.2831853 * (float3(1.0, 1.0, 1.0) * t + float3(0.0, 0.33, 0.67))); }
fragment float4 art_fragment(V in [[stage_in]], constant float &aspect [[buffer(0)]])
{
	float2 uv = in.uv;
	float2 c = float2(-0.7453 + (uv.x - 0.5) * 0.09 * aspect, 0.1127 + (uv.y - 0.5) * 0.09);
	float2 z = float2(0.0);
	float n = 0.0;
	for (int i = 0; i < 400; i++) {
		z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
		if (dot(z, z) > 256.0) break;
		n += 1.0;
	}
	float3 col;
	if (n >= 400.0) col = float3(0.02, 0.02, 0.05);
	else {
		float sm = n - log2(log2(dot(z, z))) + 4.0;	/* smooth iteration count */
		col = rainbow(sm * 0.035 + 0.6) * (0.55 + 0.45 * sin(sm * 0.25));
	}
	float2 q = uv - 0.5;
	float r = length(q);
	float glow = exp(-pow((r - 0.42) * 40.0, 2.0)) + 0.6 * exp(-pow((r - 0.30) * 60.0, 2.0));
	col += glow * rainbow(atan2(q.y, q.x) / 6.2831853 + 0.5);
	col *= smoothstep(0.75, 0.25, r) * 0.35 + 0.65;	/* vignette */
	return float4(saturate(col), 1.0);
}
