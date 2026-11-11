shader_type spatial;
// Lightning core: opaque and depth-writing, so the raymarched funnel (which
// stops at scene depth) hides a channel behind it and shows one in front.
// HDR albedo: the glow pass blooms it.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

#include "res://shaders/tornado/tornado_bolt.gdshaderinc"

uniform float core_energy = 40.0;

void fragment() {
	float x = abs(v_side);
	if (x > 0.7) {
		discard;
	}
	ALBEDO = bolt_color * (1.0 - smoothstep(0.35, 1.0, x)) * core_energy * v_thin
		* v_intensity * bolt_level;
}
