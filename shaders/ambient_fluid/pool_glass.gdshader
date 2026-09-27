shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never;

uniform vec3 glass_color : source_color = vec3(0.4, 0.66, 0.75);
uniform float base_alpha : hint_range(0.0, 0.55) = 0.01;

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = glass_color;
	ROUGHNESS = 0.14;
	SPECULAR = 0.35;
	ALPHA = base_alpha + fresnel * 0.07;
}
