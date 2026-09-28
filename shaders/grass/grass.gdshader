shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, ensure_correct_normals;

group_uniforms Terrain;
uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float heightmap_scale = 5.0;

group_uniforms GrassProperties;
uniform int demo_stage : hint_range(0, 3) = 3;
uniform float clumping_factor : hint_range(0.0, 1.0) = 0.55;
uniform sampler2D clump_noise : filter_linear, repeat_enable;
uniform sampler2D wind_noise : filter_linear, repeat_enable;
uniform sampler2D plume_mask : source_color, filter_linear, repeat_disable;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform vec2 wind_direction = vec2(0.819, 0.574);
uniform float gustiness : hint_range(0.0, 1.0) = 0.65;
uniform float gust_pulse : hint_range(0.0, 1.0) = 0.0;
uniform float gust_age = 0.0;
uniform vec2 gust_origin = vec2(0.0);

group_uniforms GrassColor;
uniform vec3 base_color : source_color = vec3(0.14, 0.23, 0.1);
uniform vec3 tip_color : source_color = vec3(0.58, 0.54, 0.28);
uniform vec3 subsurface_scattering_color : source_color = vec3(0.8, 0.69, 0.45);
uniform vec3 plume_color : source_color = vec3(0.68, 0.61, 0.51);
uniform float chromatic_strength : hint_range(0.0, 1.0) = 0.0;

varying vec3 grass_world_root;
varying float grass_color_variation;
varying float grass_part;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

mat3 rotate_y(float angle) {
	float s = sin(angle);
	float c = cos(angle);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

float ease_in_quartic(float value) {
	float squared = value * value;
	return squared * squared;
}

void vertex() {
	vec3 blade_root = MODEL_MATRIX[3].xyz;
	float blade_height = UV.y;
	float pampas_part = step(1.5, UV.x);
	float pampas_presence = step(0.25, INSTANCE_CUSTOM.a) * step(1.5, float(demo_stage));
	float blade_id = INSTANCE_CUSTOM.b;
	float feature_mix = smoothstep(0.5, 1.0, float(demo_stage));

	float height_variation = mix(1.0, mix(0.78, 1.2, INSTANCE_CUSTOM.r), feature_mix);
	float width_variation = mix(1.0, mix(0.83, 1.18, INSTANCE_CUSTOM.g), feature_mix);
	float broad_clump = texture(clump_noise, blade_root.xz * 0.004).r;
	float fine_clump = texture(clump_noise, blade_root.xz * 0.018).r;
	float height_clump = mix(1.0, mix(0.82, 1.18, broad_clump),
		clumping_factor * feature_mix);
	height_variation *= height_clump;

	float random_angle = INSTANCE_CUSTOM.b * TAU * feature_mix;
	float clump_angle = (fine_clump - 0.5) * 0.9;
	float blade_angle = mix(random_angle, clump_angle, clumping_factor * feature_mix);
	mat3 blade_rotation = rotate_y(blade_angle);
	vec3 blade_position = VERTEX * mix(1.0, pampas_presence, pampas_part);
	blade_position.x *= width_variation;
	blade_position.y *= height_variation;
	blade_position = blade_rotation * blade_position;

	vec2 direction = normalize(wind_direction);
	vec2 crosswind = vec2(-direction.y, direction.x);
	float wind_amount = clamp(wind_speed / 2.0, 0.0, 1.0);
	float along_wind = dot(blade_root.xz, direction);
	vec2 broad_uv = blade_root.xz * 0.004 - direction * (TIME * wind_speed * 0.008);
	float broad_noise = texture(wind_noise, broad_uv).r;
	float wave_phase = along_wind * 0.23 - TIME * (0.5 + wind_speed * 0.35)
		+ (broad_noise - 0.5) * 1.4;
	float wave_front = 0.5 + 0.5 * sin(wave_phase);
	vec2 fine_uv = blade_root.xz * 0.035 - direction * (TIME * wind_speed * 0.035);
	float fine_wind = texture(wind_noise, fine_uv + vec2(blade_id * 0.13)).r;
	float turbulence = (fine_wind - 0.5) * 0.13 * wind_amount;
	float gust_distance = dot(blade_root.xz - gust_origin, direction) + 4.0;
	float gust_front = gust_age * (6.0 + max(wind_speed, 1.0) * 3.0) - gust_distance;
	float gust_band = smoothstep(0.0, 7.0, gust_front)
		* (1.0 - smoothstep(14.0, 26.0, gust_front));
	float bend = wind_amount * (0.1 + wave_front * gustiness * 1.4)
		+ gust_pulse * gust_band * (0.4 + wave_front * 0.7) + turbulence;
	float tip_weight = ease_in_quartic(blade_height);
	float flutter = sin(TIME * (2.5 + wind_speed * 1.5) + blade_id * TAU
		+ along_wind * 0.15) * 0.12 * wind_amount * tip_weight;
	blade_position.xz += direction * (bend * tip_weight) + crosswind * (flutter * tip_weight);
	blade_position.y -= bend * tip_weight * 0.18;

	float terrain_height = (texture(heightmap,
		blade_root.xz / vec2(textureSize(heightmap, 0))).r - 0.5) * heightmap_scale;
	blade_position.y += terrain_height;
	VERTEX = blade_position;
	NORMAL = normalize(mix(blade_rotation * NORMAL, vec3(0.0, 1.0, 0.0), 0.28));
	grass_world_root = blade_root;
	grass_color_variation = INSTANCE_CUSTOM.a;
	grass_part = floor(UV.x * 0.5);
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
	float clump_value = texture(clump_noise, grass_world_root.xz * 0.004).r;
	ALBEDO *= mix(1.0, mix(0.9, 1.08, clump_value), feature_mix * clumping_factor);
	float head_part = step(0.5, grass_part) * (1.0 - step(1.5, grass_part));
	vec4 plume = texture(plume_mask, vec2(UV.x - 2.0, 1.0 - clamp((UV.y - 0.75) * 4.0, 0.0, 1.0)));
	ALBEDO = mix(ALBEDO, plume.rgb * plume_color, head_part * color_mix);
	ALBEDO = mix(ALBEDO, stage_base * 0.8, step(1.5, grass_part));
	float chromatic_phase = grass_world_root.x * 0.013 + grass_world_root.z * 0.009;
	vec3 chromatic = 0.5 + 0.5 * cos(TAU * (chromatic_phase + vec3(0.0, 0.34, 0.68)));
	ALBEDO = mix(ALBEDO, chromatic * mix(0.3, 0.8, height_factor), chromatic_strength * color_mix);
	ALPHA = mix(1.0, plume.a, head_part);
	ALPHA_SCISSOR_THRESHOLD = 0.18;
	ROUGHNESS = mix(0.93, 0.78, tip_blend);
	ANISOTROPY = 0.2;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float wrapped_diffuse = clamp((ndotl + 0.45) / 1.45, 0.0, 1.0);
	float backlight = max(-ndotl, 0.0) * 0.08;
	DIFFUSE_LIGHT += (wrapped_diffuse + backlight * subsurface_scattering_color)
		* ATTENUATION * LIGHT_COLOR / PI;
	SPECULAR_LIGHT *= wrapped_diffuse;
}
