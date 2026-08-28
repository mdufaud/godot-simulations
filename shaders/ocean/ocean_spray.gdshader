shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#define GRID 128
#define CASCADES 3

uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform sampler2DArray normals : filter_linear, repeat_enable;
uniform sampler2DArray foam_history_a : filter_linear, repeat_enable;
uniform sampler2DArray foam_history_b : filter_linear, repeat_enable;
uniform vec4 foam_history_indices = vec4(0.0);
// P3-B: spawn is rejected below this breaking level; 0 rolls back to the
// mood-only gate.
uniform float spray_breaking_threshold = 0.2;
uniform vec4 map_scales[CASCADES];
uniform vec2 window_center = vec2(0.0);
uniform float window_size = 168.0;
uniform float storm_mood = 0.0;
uniform float spray_amount = 0.0;
uniform float sim_time = 0.0;
uniform float min_pixel_size = 0.75;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform vec3 spray_color : source_color = vec3(0.64, 0.78, 0.77);

varying float particle_alpha;
varying vec2 particle_uv;

float hash11(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

vec2 hash21(float p) {
	return fract(sin(vec2(p * 127.1, p * 311.7)) * vec2(43758.5453, 22578.1459));
}

void vertex() {
	int ix = int(INSTANCE_ID) % GRID;
	int iz = int(INSTANCE_ID) / GRID;
	float seed = float(INSTANCE_ID) + 17.0;
	vec2 jitter = (hash21(seed) - 0.5) * window_size / float(GRID);
	vec2 cell = (vec2(float(ix), float(iz)) + 0.5) / float(GRID) - 0.5;
	vec2 xz = window_center + cell * window_size + jitter;

	vec3 displacement = vec3(0.0);
	float crest = 0.0;
	float breaking = 0.0;
	for (int i = 0; i < CASCADES; i++) {
		vec3 coords = vec3(xz * map_scales[i].xy, float(i));
		displacement += textureLod(displacements, coords, 0.0).xyz;
		vec4 normal_sample = textureLod(normals, coords, 0.0);
		crest = max(crest, normal_sample.z);
		breaking = max(breaking, normal_sample.a);
	}

	// P3-B: the foam feedback confirms active breaking — spawn is rejected
	// where the fresh channel is empty even if the instantaneous breaking texel
	// fires. Threshold 0 rolls back to the mood-only gate.
	float foam_signal = 0.0;
	if (spray_breaking_threshold > 0.0) {
		for (int i = 0; i < 2; i++) {
			float read_b = i == 0 ? foam_history_indices.x : foam_history_indices.y;
			vec3 foam_coords = vec3(xz * map_scales[i].xy, float(i));
			vec4 foam_sample = read_b > 0.5
				? textureLod(foam_history_b, foam_coords, 0.0)
				: textureLod(foam_history_a, foam_coords, 0.0);
			foam_signal = max(foam_signal, foam_sample.g);
		}
	}

	float cycle = fract(sim_time * mix(0.18, 0.31, hash11(seed + 9.0)) + hash11(seed));
	float life = sin(cycle * 3.14159265);

	vec3 center = vec3(xz.x + displacement.x, displacement.y, xz.y + displacement.z);
	float backlight = pow(max(dot(normalize(CAMERA_POSITION_WORLD - center),
		-normalize(sun_direction)), 0.0), 2.0);
	float weather_gate = smoothstep(0.12, 0.62, storm_mood);
	float breaking_gate = spray_breaking_threshold > 0.0
		? smoothstep(spray_breaking_threshold, spray_breaking_threshold + 0.22, breaking)
			* smoothstep(0.015, 0.10, foam_signal)
		: smoothstep(0.06, 0.28, breaking);
	float gate = breaking_gate * weather_gate
		* mix(0.55, 1.0, backlight) * spray_amount;
	float sparse = step(hash11(seed + 41.0), clamp(gate * 0.68, 0.0, 1.0));
	particle_alpha = life * life * gate * sparse * 0.58;

	float spindrift = step(0.68, hash11(seed + 101.0));
	float launch_arc = life * mix(0.35, 1.7, storm_mood);
	float gravity_arc = cycle * cycle * mix(0.3, 1.2, spindrift);
	center.y += 2.5 + crest * 1.8 + launch_arc - gravity_arc;
	center.xz += wind_direction * cycle * mix(0.35, 2.4, storm_mood)
		+ (hash21(seed + 73.0) - 0.5) * cycle * mix(0.35, 1.8, storm_mood);
	vec3 center_view = (VIEW_MATRIX * vec4(center, 1.0)).xyz;
	particle_uv = UV * 2.0 - 1.0;
	float size = mix(0.05, 0.30, hash11(seed + 23.0))
		* mix(0.7, 1.35, storm_mood);
	vec2 billboard = vec2(particle_uv.x * size,
		particle_uv.y * size * mix(2.6, 5.4, spindrift));
	float distance_to_camera = max(-center_view.z, 0.001);
	float pixel_world = 2.0 * distance_to_camera
		/ (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1]);
	float pixel_size = max(size, min_pixel_size * pixel_world);
	billboard *= pixel_size / max(size, 0.001);
	POSITION = PROJECTION_MATRIX * vec4(center_view + vec3(billboard, 0.0), 1.0);
}

void fragment() {
	float radius = dot(particle_uv, particle_uv);
	if (radius > 1.0 || particle_alpha < 0.002) {
		discard;
	}
	float soft = exp(-3.8 * radius) - exp(-3.8);
	ALBEDO = spray_color * soft * particle_alpha;
	ALPHA = soft * particle_alpha;
}
