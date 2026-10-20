shader_type spatial;
// Fuel log on the Fire-X bark/endgrain textures. Heat chars the wood black and
// makes the hot zone glow red-hot all over, a notch hotter in the ember cracks,
// pulsing slowly. heat 0 is plain bark.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D ember_tex : filter_linear_mipmap;
uniform sampler2D pulse_tex : filter_linear_mipmap, repeat_enable;
uniform bool use_normal = false;
uniform float heat = 0.0;
uniform vec3 heat_center = vec3(0.0);
uniform float heat_radius_m = 1.0;
uniform float glow_energy = 5.0;

varying vec3 v_world;

// Blackbody-like ramp: dull red, cherry red, orange.
vec3 ember_ramp(float t) {
	vec3 low = mix(vec3(0.3, 0.015, 0.0), vec3(1.0, 0.1, 0.01), smoothstep(0.0, 0.5, t));
	return mix(low, vec3(1.0, 0.45, 0.08), smoothstep(0.5, 1.0, t));
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float local = heat * (1.0 - smoothstep(heat_radius_m * 0.3, heat_radius_m,
		distance(v_world.xz, heat_center.xz)));
	vec3 bark = texture(albedo_tex, UV).rgb;
	ALBEDO = mix(bark, vec3(0.02, 0.018, 0.016), clamp(local * 1.5, 0.0, 0.95));
	ROUGHNESS = 0.95;
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	float cracks = texture(ember_tex, UV).r;
	float pulse = texture(pulse_tex, v_world.xz * 0.7 + vec2(TIME * 0.07, TIME * 0.05)).r;
	float temperature = clamp(local * (0.3 + 0.3 * pulse + 0.4 * cracks), 0.0, 1.0);
	float glow = local * (0.15 + 0.35 * pulse) + local * cracks * 1.6;
	EMISSION = ember_ramp(temperature) * glow * glow_energy;
}
