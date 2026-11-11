shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Bed of glowing coals on the ground under a fire: a horizontal disc of hot
// veins between darker coals, breathing slowly. Additive, so the ground and
// the logs standing in it keep their own shading.
// Driven per fire through instance shader parameters.

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float glow_energy = 1.1;

instance uniform float bed_intensity = 0.0;
instance uniform float bed_seed = 0.0;

// Blackbody-like ramp: dull red, cherry red, orange.
vec3 ember_ramp(float t) {
	vec3 low = mix(vec3(0.3, 0.015, 0.0), vec3(1.0, 0.1, 0.01), smoothstep(0.0, 0.5, t));
	return mix(low, vec3(1.0, 0.45, 0.08), smoothstep(0.5, 1.0, t));
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	vec2 p = UV * 1.4 + bed_seed;
	float veins = smoothstep(0.42, 0.7, texture(noise_tex, p * 2.2).r);
	float pulse = texture(noise_tex, p * 0.5 + vec2(TIME * 0.05, TIME * 0.035)).r;
	float heat = (1.0 - smoothstep(0.1, 0.9, r)) * (0.15 + 0.85 * veins) * (0.4 + 1.2 * pulse)
		* bed_intensity;
	ALBEDO = ember_ramp(clamp(heat, 0.0, 1.0)) * heat * glow_energy;
}
