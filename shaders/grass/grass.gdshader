shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, ensure_correct_normals;

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
uniform sampler2D wind_noise : filter_linear, repeat_enable;
uniform sampler2D plume_mask : source_color, filter_linear, repeat_disable;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform vec2 wind_direction = vec2(0.819, 0.574);
uniform float gustiness : hint_range(0.0, 1.0) = 0.65;
uniform float gust_pulse : hint_range(0.0, 1.0) = 0.0;
uniform float gust_age = -1.0;
uniform vec2 gust_origin = vec2(0.0);
uniform vec2 gust_direction = vec2(0.819, 0.574);
uniform float gust_speed = 15.0;
uniform float gust_phase = 0.0;
// Wind phase pre-accumulated on the CPU and wrapped there: float32 TIME keeps
// fine-graining after hours of play, which shimmers the scroll. See tick().
uniform float wind_time = 0.0;
uniform float wave_time = 0.0;

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

float wind_flutter(float time, float speed, float phase, float age, float pulse, float band) {
	float amount = clamp(speed / 5.0, 0.0, 1.0);
	return sin(time * (2.5 + speed * 1.5) + phase) * 0.045 * amount
		+ sin(age * 7.0 + phase) * 0.036 * amount * pulse * band;
}

void vertex() {
	vec3 blade_root = MODEL_MATRIX[3].xyz;
	float pampas_part = step(1.5, UV.x);
	float plume_head = pampas_part * (1.0 - step(3.5, UV.x));
	// INSTANCE_CUSTOM.a is also the color variation; the 0.25 gate keeps ~25%
	// of the tufts plume-less so the stage-3 field is not uniformly plumed.
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

	vec2 direction = normalize(wind_direction);
	vec2 crosswind = vec2(-direction.y, direction.x);
	float wind_amount = clamp(wind_speed / 5.0, 0.0, 1.0);
	float along_wind = dot(blade_root.xz, direction);
	// Three decorrelated octaves of scrolling wind (the large offsets re-seed
	// the seamless noise): broad bends the wave phase, band breathes its
	// amplitude so gust lanes appear and dissolve, fine drives the shiver.
	vec2 scroll = direction * wind_time;
	float broad_noise = texture(wind_noise, blade_root.xz * 0.004 - scroll * 0.008).r;
	float band_noise = texture(wind_noise, blade_root.xz * 0.013 - scroll * 0.02
		+ vec2(0.41, 0.23)).r;
	float fine_wind = texture(wind_noise, blade_root.xz * 0.035 - scroll * 0.035
		+ vec2(blade_id * 0.13)).r;
	float wave_phase = along_wind * 0.23 - wave_time
		+ (broad_noise - 0.5) * 2.2;
	float wave_front = (0.5 + 0.5 * sin(wave_phase))
		* (0.4 + 0.6 * smoothstep(0.3, 0.7, band_noise));
	float turbulence = (fine_wind - 0.5) * 0.16 * wind_amount;
	float local_wind = mix(wave_front, fine_wind, 0.6);

	// The burst: a ragged wavefront sweeping downwind. Noise breaks the strip
	// into clumps, the trailing dip over-swings the blades back, and the extra
	// shiver terms only live inside the band.
	float gust_distance = dot(blade_root.xz - gust_origin, gust_direction);
	vec2 gust = gust_envelope(gust_distance, gust_age, gust_speed);
	float gust_band = gust.x * (0.75 + 0.5 * texture(wind_noise, blade_root.xz * 0.02
			+ vec2(gust_phase, gust_phase * 1.7)).r);
	float gust_recoil = gust.y;
	float compliance = mix(0.78, 1.22, INSTANCE_CUSTOM.g);
	float bend_angle = wind_amount * (0.16 + local_wind * gustiness * 1.5)
		+ turbulence * 0.45;
	bend_angle = clamp(bend_angle, -0.18, 1.05);
	bend_angle += gust_pulse * compliance
		* (gust_band * (0.65 + wave_front * 0.35) - gust_recoil * 0.16
			+ (fine_wind - 0.5) * 0.08 * gust_band);
	bend_angle = clamp(bend_angle, -0.18, 1.4);
	float flutter_phase = blade_id * TAU + along_wind * 0.15;
	float flutter = wind_flutter(TIME, wind_speed, flutter_phase, gust_age, gust_pulse, gust_band);
	vec2 bend = direction * bend_angle + crosswind * flutter;
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
	NORMAL = normalize(mix(bent_normal, vec3(0.0, 1.0, 0.0), 0.12));
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
	AO = mix(0.55, 1.0, smoothstep(0.0, 0.7, height_factor));
	ROUGHNESS = 0.94;
	cloud_transmittance = texture(cloud_shadow_texture,
		(grass_world_root.xz - cloud_shadow_center) / cloud_shadow_extent + 0.5).r;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float wrapped_diffuse = clamp((ndotl + 0.65) / 1.65, 0.0, 1.0);
	float backlight = max(-ndotl, 0.0) * 0.35;
	DIFFUSE_LIGHT += (wrapped_diffuse + backlight * subsurface_scattering_color)
		* ATTENUATION * LIGHT_COLOR * cloud_transmittance / PI;
	vec3 halfway = normalize(LIGHT + VIEW);
	float sun_glint = pow(max(dot(NORMAL, halfway), 0.0), 24.0) * max(ndotl, 0.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * cloud_transmittance * sun_glint * 0.025;
}
