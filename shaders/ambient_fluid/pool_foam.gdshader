shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform float foam_opacity : hint_range(0.0, 1.0) = 0.4;

void fragment() {
	ALBEDO = vec3(0.72, 0.94, 0.94);
	ALPHA = foam_opacity;
}
