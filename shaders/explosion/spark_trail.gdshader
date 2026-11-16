shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, particle_trails;

uniform float gain = 1.0;

void fragment() {
	ALBEDO = COLOR.rgb * gain;
	ALPHA = COLOR.a;
}
