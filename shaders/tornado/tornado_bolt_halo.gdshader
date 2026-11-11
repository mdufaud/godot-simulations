shader_type spatial;
// Lightning halo: the lit air around the channel. Additive, depth-tested
// without writing depth.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled, skip_vertex_transform;

#include "res://shaders/tornado/tornado_bolt.gdshaderinc"

uniform float halo_energy = 0.9;

void fragment() {
	float x = abs(v_side);
	ALBEDO = bolt_color * exp(-x * x * 6.0) * halo_energy * v_intensity * bolt_level;
}
