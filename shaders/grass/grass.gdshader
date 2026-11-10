shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, ensure_correct_normals;

#include "res://shaders/grass/wind_field.gdshaderinc"

uniform sampler2D cloud_shadow_texture : hint_default_white, filter_linear, repeat_disable;
uniform vec2 cloud_shadow_center = vec2(0.0);
uniform float cloud_shadow_extent = 256.0;

group_uniforms Terrain;
uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float heightmap_scale = 5.0;

group_uniforms GrassProperties;
uniform int demo_stage : hint_range(0, 3) = 3;
uniform float clumping_factor : hint_range(0.0, 1.0) = 0.55;
uniform sampler2D clump_noise : filter_linear, repeat_enable;
uniform sampler2D plume_mask : source_color, filter_linear, repeat_disable;
uniform float height_scale : hint_range(0.2, 1.5) = 1.0;
uniform float plume_density : hint_range(0.0, 1.0) = 0.75;
uniform float gust_pulse : hint_range(0.0, 1.0) = 0.0;
uniform float gust_age = -1.0;
uniform vec2 gust_origin = vec2(0.0);
uniform vec2 gust_direction = vec2(0.819, 0.574);
uniform float gust_speed = 15.0;
uniform float gust_phase = 0.0;
// Phases of the two sway modes around the stems' natural frequency, wrapped
// to TAU on the CPU: float32 TIME coarsens after hours of play. See tick().
uniform vec2 sway_phase = vec2(0.0);
// Radians of travelling sway phase per metre downwind (k = f0 / Uc).
uniform float sway_wavenumber = 1.6;
// Blades widen past x metres to keep the canopy closed as far tiles thin out.
uniform vec2 widen_distance_m = vec2(16.0, 75.0);
uniform float widen_gain = 1.3;

group_uniforms GrassColor;
uniform vec3 base_color : source_color = vec3(0.14, 0.23, 0.1);
uniform vec3 tip_color : source_color = vec3(0.58, 0.54, 0.28);
uniform vec3 subsurface_scattering_color : source_color = vec3(0.8, 0.69, 0.45);
uniform vec3 plume_color : source_color = vec3(0.68, 0.61, 0.51);
uniform float chromatic_strength : hint_range(0.0, 1.0) = 0.0;

varying vec3 grass_world_root;
varying float grass_color_variation;
varying float grass_part;
varying float cloud_transmittance;
// Per-tuft constants taken once in vertex(): every vertex of a tuft shares its
// root, so these are flat across it and the fragment stage need not refetch them.
varying float grass_clump;
varying float grass_wind;
varying float grass_distance;
varying float grass_height_factor;
varying float grass_sheen;
varying float grass_pasture;

mat3 rotate_y(float angle) {
	float s = sin(angle);
	float c = cos(angle);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

mat3 bend_rotation(vec2 bend, float fraction) {
	float magnitude = length(bend);
	if (magnitude < 0.00001) {
		return mat3(1.0);
	}
	vec3 axis = vec3(bend.y, 0.0, -bend.x) / magnitude;
	float s = sin(magnitude * fraction);
	float c = cos(magnitude * fraction);
	float k = 1.0 - c;
	return mat3(
		vec3(c + axis.x * axis.x * k, axis.z * s, axis.z * axis.x * k),
		vec3(-axis.z * s, c, axis.x * s),
		vec3(axis.x * axis.z * k, -axis.x * s, c + axis.z * axis.z * k));
}

vec3 ribbon_center(vec4 root_height, vec4 curve, float t, float leaf) {
	vec3 position = root_height.xyz + vec3(curve.z, 0.0, curve.w) * curve.x * t * t;
	position.y += root_height.w * (t - leaf * 0.25 * t * t * t);
	return position;
}

vec3 bent_ribbon_center(vec4 root_height, vec4 curve, float t, float leaf,
		mat3 rest_transform, vec2 bend) {
	vec3 position = rest_transform * root_height.xyz;
	vec3 previous = position;
	for (int segment = 0; segment < 4; segment++) {
		float start = float(segment) / curve.y;
		if (start >= t) {
			break;
		}
		float end = min(t, float(segment + 1) / curve.y);
		vec3 next = rest_transform * ribbon_center(root_height, curve, end, leaf);
		position += bend_rotation(bend, (float(segment) + 0.5) / curve.y) * (next - previous);
		previous = next;
	}
	return position;
}

vec3 bend_tuft_vertex(vec3 position, vec4 root_height, vec4 curve, float station,
		float pampas, float head, float presence, mat3 rest_transform, vec2 bend,
		out mat3 normal_rotation) {
	normal_rotation = mat3(1.0);
	if (pampas > 0.5 && presence < 0.5) {
		return vec3(0.0);
	}
	if (head > 0.5) {
		vec3 pivot = rest_transform * vec3(0.71 * 0.38, 1.1, 0.71 * 0.38);
		vec3 bent_pivot = bent_ribbon_center(vec4(0.0, 0.0, 0.0, 1.1),
			vec4(0.38, 2.0, 0.71, 0.71), 1.0, 0.0, rest_transform, bend);
		normal_rotation = bend_rotation(bend, 0.75);
		return bent_pivot + normal_rotation * (position - pivot);
	}
	if (curve.y > 0.0) {
		float leaf = 1.0 - pampas;
		normal_rotation = bend_rotation(bend, min(station, 1.0 - 0.5 / curve.y));
		vec3 center = rest_transform * ribbon_center(root_height, curve, station, leaf);
		return bent_ribbon_center(root_height, curve, station, leaf, rest_transform, bend)
			+ normal_rotation * (position - center);
	}
	normal_rotation = bend_rotation(bend, 1.0);
	return normal_rotation * position;
}

vec2 gust_envelope(float distance, float age, float speed) {
	float front = age * speed - distance;
	return vec2(smoothstep(0.0, 45.0, front) * (1.0 - smoothstep(80.0, 150.0, front)),
		smoothstep(150.0, 190.0, front) * (1.0 - smoothstep(190.0, 275.0, front)))
		* step(0.0, distance);
}

void vertex() {
	vec3 blade_root = MODEL_MATRIX[3].xyz;
	float pampas_part = step(1.5, UV.x);
	float plume_head = pampas_part * (1.0 - step(3.5, UV.x));
	// INSTANCE_CUSTOM.a is also the color variation; the 0.25 gate keeps ~25%
	// of the tufts plume-less so the stage-3 field is not uniformly plumed.
	float pampas_presence = step(1.0 - plume_density, INSTANCE_CUSTOM.a)
		* step(1.5, float(demo_stage));
	float blade_id = INSTANCE_CUSTOM.b;
	float feature_mix = smoothstep(0.5, 1.0, float(demo_stage));

	float height_variation = mix(1.0, mix(0.78, 1.2, INSTANCE_CUSTOM.r), feature_mix);
	float width_variation = mix(1.0, mix(0.83, 1.18, INSTANCE_CUSTOM.g), feature_mix);
	float broad_clump = texture(clump_noise, blade_root.xz * 0.004).r;
	float fine_clump = texture(clump_noise, blade_root.xz * 0.018).r;
	float height_clump = mix(1.0, mix(0.82, 1.18, broad_clump),
		clumping_factor * feature_mix);
	height_variation *= height_clump * height_scale;
	grass_distance = distance(blade_root, CAMERA_POSITION_WORLD);
	width_variation *= 1.0 + widen_gain
		* smoothstep(widen_distance_m.x, widen_distance_m.y, grass_distance);

	float random_angle = INSTANCE_CUSTOM.b * TAU * feature_mix;
	float clump_angle = (fine_clump - 0.5) * 0.9;
	float blade_angle = mix(random_angle, clump_angle, clumping_factor * feature_mix);
	mat3 blade_rotation = rotate_y(blade_angle);
	mat3 rest_transform = blade_rotation * mat3(
		vec3(width_variation, 0.0, 0.0), vec3(0.0, height_variation, 0.0), vec3(0.0, 0.0, 1.0));
	vec3 blade_position = rest_transform * VERTEX;
	vec3 head_pivot = rest_transform * vec3(0.71 * 0.38, 1.1, 0.71 * 0.38);
	float plume_size = mix(0.82, 1.2, INSTANCE_CUSTOM.r);
	float plume_roll = (INSTANCE_CUSTOM.b - 0.5) * 0.7;
	if (plume_head > 0.5 && pampas_presence > 0.5) {
		vec3 head_offset = blade_position - head_pivot;
		blade_position = head_pivot
			+ rotate_y(plume_roll) * head_offset * mix(1.0, plume_size, feature_mix);
	}

	vec4 wind = wind_field(blade_root.xz);
	float wind_amount = clamp(wind_speed / 5.0, 0.0, 1.0);
	vec2 direction = wind.z > 0.0001 ? wind.xy / wind.z : normalize(wind_direction);
	vec2 crosswind = vec2(-direction.y, direction.x);

	// The burst: a ragged wavefront sweeping downwind. Noise breaks the strip
	// into clumps, the trailing dip over-swings the blades back, and the extra
	// shiver terms only live inside the band.
	float gust_distance = dot(blade_root.xz - gust_origin, gust_direction);
	vec2 gust = gust_envelope(gust_distance, gust_age, gust_speed);
	float gust_band = gust.x * (0.75 + 0.5 * texture(wind_noise, blade_root.xz * 0.02
			+ vec2(gust_phase, gust_phase * 1.7)).r);
	float gust_recoil = gust.y;
	float compliance = mix(0.78, 1.22, INSTANCE_CUSTOM.g);
	// Drag grows with the square of the wind, and a blade already lying
	// downwind catches less of it, so the lean saturates.
	float drive = wind.z * (0.35 + 0.65 * wind.z);
	float bend_angle = 1.15 * (1.0 - exp(-1.5 * drive)) * compliance
		+ wind.w * 0.3 * wind_amount;
	bend_angle = clamp(bend_angle, -0.18, 1.05);
	float burst = gust_pulse * compliance
		* (gust_band * (0.65 + wind.z * 0.35) - gust_recoil * 0.16
			+ wind.w * 0.08 * gust_band);
	// Stems ring near their natural frequency whatever the wind speed; the
	// phase travels downwind and each tuft sits between two nearby modes.
	float travel = dot(blade_root.xz, normalize(wind_direction)) * sway_wavenumber;
	float sway_seed = blade_id * TAU;
	float sway_mix = INSTANCE_CUSTOM.r;
	float sway = mix(sin(sway_phase.x - travel + sway_seed),
		sin(sway_phase.y - travel * 1.3 + sway_seed * 1.7), sway_mix);
	float flutter = sin(sway_phase.x + sway_phase.y + sway_seed * 2.9 - travel * 0.7);
	float sway_amount = wind_amount * (0.03 + 0.2 * wind.z * wind.z) + 0.05 * gust_pulse * gust_band;
	bend_angle += sway * sway_amount;
	vec2 bend = direction * bend_angle + normalize(gust_direction) * burst
		+ crosswind * flutter * sway_amount * 0.6;
	grass_wind = clamp(length(bend), 0.0, 1.4);
	float station = pampas_part < 0.5 ? UV.y : UV.y / 0.75;
	mat3 normal_rotation;
	blade_position = bend_tuft_vertex(blade_position, CUSTOM0, CUSTOM1, station,
		pampas_part, plume_head, pampas_presence, rest_transform, bend, normal_rotation);

	float terrain_height = (texture(heightmap,
		blade_root.xz / vec2(textureSize(heightmap, 0))).r - 0.5) * heightmap_scale;
	blade_position.y += terrain_height;
	VERTEX = blade_position;
	vec3 bent_normal = blade_rotation * normalize(NORMAL
		/ vec3(width_variation, height_variation, 1.0));
	if (plume_head > 0.5 && pampas_presence > 0.5) {
		bent_normal = rotate_y(plume_roll) * bent_normal;
	}
	bent_normal = normal_rotation * bent_normal;
	// Far blades shade as one soft canopy: their own normals only add noise.
	NORMAL = normalize(mix(bent_normal, vec3(0.0, 1.0, 0.0),
		mix(0.12, 0.7, smoothstep(10.0, 70.0, grass_distance))));
	grass_world_root = blade_root;
	grass_color_variation = INSTANCE_CUSTOM.a;
	grass_part = floor(UV.x * 0.5);
	grass_clump = broad_clump;
	grass_pasture = texture(clump_noise, blade_root.xz * 0.0011).r;
	grass_height_factor = clamp(UV.y, 0.0, 1.0);
	cloud_transmittance = texture(cloud_shadow_texture,
		(blade_root.xz - cloud_shadow_center) / cloud_shadow_extent + 0.5).r;
}

void fragment() {
	float height_factor = clamp(UV.y, 0.0, 1.0);
	float feature_mix = smoothstep(0.5, 1.0, float(demo_stage));
	float color_mix = smoothstep(1.5, 2.0, float(demo_stage));
	float color_variation = mix(1.0, mix(0.9, 1.08, grass_color_variation), feature_mix);
	vec3 neutral_base = vec3(0.17, 0.23, 0.1);
	vec3 neutral_tip = vec3(0.38, 0.45, 0.21);
	vec3 stage_base = mix(neutral_base, base_color, color_mix);
	vec3 stage_tip = mix(neutral_tip, tip_color, color_mix);
	float tip_blend = smoothstep(0.12, 0.95, height_factor);
	ALBEDO = mix(stage_base, stage_tip, tip_blend) * color_variation;
	ALBEDO *= mix(1.0, mix(0.9, 1.08, grass_clump), feature_mix * clumping_factor);
	// Pasture-scale drift between lush and sun-dried stands, shared with the far ground.
	ALBEDO *= mix(1.0, mix(0.78, 1.1, grass_pasture), color_mix);
	float head_part = step(0.5, grass_part) * (1.0 - step(1.5, grass_part));
	// Only plume heads read the mask; elsewhere head_part zeroes both its uses.
	// plume_mask has no mips, so the branch needs no derivatives.
	vec4 plume = vec4(1.0);
	if (head_part > 0.5) {
		plume = texture(plume_mask, vec2(UV.x - 2.0, 1.0 - clamp((UV.y - 0.75) * 4.0, 0.0, 1.0)));
	}
	ALBEDO = mix(ALBEDO, plume.rgb * plume_color, head_part * color_mix);
	ALBEDO = mix(ALBEDO, stage_base * 0.8, step(1.5, grass_part));
	float chromatic_phase = grass_world_root.x * 0.013 + grass_world_root.z * 0.009;
	vec3 chromatic = 0.5 + 0.5 * cos(TAU * (chromatic_phase + vec3(0.0, 0.34, 0.68)));
	ALBEDO = mix(ALBEDO, chromatic * mix(0.3, 0.8, height_factor), chromatic_strength * color_mix);
	ALPHA = mix(1.0, plume.a, head_part);
	ALPHA_SCISSOR_THRESHOLD = 0.18;
	// Leaning blades turn their faces to the sky: gusts read as pale, glossy
	// patches racing over the field.
	float sheen = smoothstep(0.12, 0.8, grass_wind) * smoothstep(0.1, 0.7, height_factor)
		* (1.0 - head_part);
	ALBEDO = mix(ALBEDO, stage_tip * 1.5 + 0.05, 0.55 * sheen);
	AO = mix(0.4, 1.0, smoothstep(0.0, 0.7, height_factor));
	ROUGHNESS = mix(0.94, 0.62, sheen);
	grass_sheen = sheen;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float wrapped_diffuse = clamp((ndotl + 0.65) / 1.65, 0.0, 1.0);
	// Thin blades glow when the sun sits behind them, strongest at the tips
	// and when looking toward the light.
	float toward_sun = pow(max(dot(VIEW, -LIGHT), 0.0), 3.0);
	float backlight = (max(-ndotl, 0.0) * 0.35 + toward_sun * 0.9)
		* mix(0.35, 1.0, grass_height_factor);
	DIFFUSE_LIGHT += (wrapped_diffuse + backlight * subsurface_scattering_color)
		* ATTENUATION * LIGHT_COLOR * cloud_transmittance / PI;
	vec3 halfway = normalize(LIGHT + VIEW);
	float glint_fade = 1.0 - smoothstep(25.0, 80.0, grass_distance);
	float sun_glint = pow(max(dot(NORMAL, halfway), 0.0), mix(24.0, 48.0, grass_sheen))
		* max(ndotl, 0.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * cloud_transmittance * sun_glint
		* mix(0.025, 0.16, grass_sheen) * glint_fade;
}
