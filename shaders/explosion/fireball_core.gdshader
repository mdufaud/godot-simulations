shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled, blend_mix;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float emission_energy = 1.2;
uniform vec3 colour_limb = vec3(0.85, 0.1, 0.02);
uniform vec3 colour_mid = vec3(1.0, 0.45, 0.08);
uniform vec3 colour_core = vec3(1.0, 0.88, 0.45);

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	vec2 flow = vec2(TIME * 0.9, TIME * 0.55);
	float n = texture(noise_tex, UV * vec2(2.0, 1.0) + flow).r * 0.55
		+ texture(noise_tex, UV * vec2(5.0, 2.5) - flow * 1.7).r * 0.45;
	float flicker = 0.92 + 0.08 * sin(TIME * 47.0) * sin(TIME * 31.0 + 1.3);
	float heat = clamp(pow(facing, 0.8) * 0.75 + (n - 0.5) * 1.8 + 0.1, 0.0, 1.0);
	vec3 c = mix(colour_limb, colour_mid, smoothstep(0.0, 0.5, heat));
	c = mix(c, colour_core, smoothstep(0.55, 1.0, heat));
	ALBEDO = c * emission_energy * flicker;
	ALPHA = smoothstep(0.0, 0.45, facing);
}
