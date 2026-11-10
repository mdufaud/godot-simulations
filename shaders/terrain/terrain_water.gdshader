shader_type spatial;
render_mode blend_mix, cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D velocity_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D micro_normal_tex : filter_linear_mipmap, repeat_enable;
uniform float world_size = 4.0;
uniform float grid_n = 512.0;
uniform bool snow_enabled = true;
uniform bool landscape_water = false;
uniform float water_film_m = 0.002;
// Depth over which the water column absorbs the light coming back from the bed.
uniform float water_absorb_m = 0.08;
uniform vec3 water_shallow : source_color = vec3(0.30, 0.50, 0.52);
uniform vec3 water_deep : source_color = vec3(0.03, 0.14, 0.22);
uniform vec3 sediment_tint : source_color = vec3(0.45, 0.36, 0.24);
uniform float micro_normal_strength = 0.06;

varying vec3 world_pos;

float surface_height(vec2 uv) {
	vec4 field = texture(height_tex, uv);
	return field.r + (snow_enabled ? field.b : 0.0) + field.g;
}

void vertex() {
	VERTEX.y = surface_height(UV);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 field = texture(height_tex, UV);
	if (field.g <= water_film_m || COLOR.r < 0.999) {
		discard;
	}
	// The film the solver holds back is wet ground, not open water.
	float coverage = smoothstep(water_film_m, water_film_m * 3.0, field.g);
	float texel = 1.0 / grid_n;
	float cell = world_size / grid_n;
	float left = surface_height(UV - vec2(texel, 0.0));
	float right = surface_height(UV + vec2(texel, 0.0));
	float down = surface_height(UV - vec2(0.0, texel));
	float up = surface_height(UV + vec2(0.0, texel));
	vec3 n_world = normalize(vec3(left - right, 2.0 * cell, down - up));
	vec2 flow = texture(velocity_tex, UV).rg;
	float scale = landscape_water ? 32.0 / world_size : 1.0;
	vec2 g = world_pos.xz * scale;
	float phase = fract(TIME * 0.5);
	vec2 drift = vec2(0.013, 0.006) * TIME;
	vec2 uv1 = (g - flow * scale * phase * 2.0 + drift) * 3.1;
	vec2 uv2 = (g - flow * scale * fract(phase + 0.5) * 2.0 + drift) * 3.1;
	vec2 ripple1 = texture(micro_normal_tex, uv1).xy * 2.0 - 1.0;
	vec2 ripple2 = texture(micro_normal_tex, uv2).xy * 2.0 - 1.0;
	vec2 ripple = mix(ripple1, ripple2, abs(phase * 2.0 - 1.0));
	float fw = fwidth(g.x + g.y) * (landscape_water ? 80.0 : 700.0);
	float detail = 1.0 / (1.0 + fw * fw * 0.15);
	n_world = normalize(n_world + vec3(ripple.x, 0.0, ripple.y) * micro_normal_strength * detail
		* (landscape_water ? 1.0 : coverage));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	float depth = 1.0 - exp(-field.g / (landscape_water ? water_absorb_m * world_size * 0.125 : water_absorb_m));
	float sediment = clamp(field.a / max(field.g, 1e-5) * 2.0, 0.0, 0.6) * depth;
	vec3 shallow = landscape_water ? vec3(0.09, 0.24, 0.28) : water_shallow;
	vec3 deep = landscape_water ? vec3(0.0072, 0.073, 0.107) : water_deep;
	ALBEDO = mix(mix(shallow, deep, depth), sediment_tint, sediment);
	ROUGHNESS = landscape_water ? 0.18 : 0.08;
	SPECULAR = landscape_water ? 0.4 : 0.7;
	float fresnel = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 5.0);
	// Clear over the bed where it is thin, its own colour only where the column is deep.
	float alpha = clamp(mix(0.22, 0.94, depth) + fresnel * 0.3 + sediment * 0.3, 0.0, 1.0);
	ALPHA = alpha * coverage;
}
