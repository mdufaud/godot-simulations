shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

void fragment() {
	float radius = length(UV - vec2(0.5)) * 2.0;
	float alpha = 1.0 - smoothstep(0.42, 1.0, radius);
	ALBEDO = vec3(0.55, 0.88, 1.0);
	ALPHA = alpha * 0.68;
}
