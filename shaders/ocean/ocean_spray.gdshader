shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#define GRID 64
#define CASCADES 3

uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform sampler2DArray normals : filter_linear, repeat_enable;
uniform vec4 map_scales[CASCADES];
uniform vec2 window_center = vec2(0.0);
uniform float window_size = 168.0;
uniform float storm_mood = 0.0;
uniform float spray_amount = 0.0;
uniform float sim_time = 0.0;
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
	for (int i = 0; i < CASCADES; i++) {
		vec3 coords = vec3(xz * map_scales[i].xy, float(i));
		displacement += textureLod(displacements, coords, 0.0).xyz;
		crest = max(crest, textureLod(normals, coords, 0.0).z);
	}

	float gate = smoothstep(0.58, 0.9, crest) * smoothstep(0.55, 0.9, storm_mood)
		* spray_amount;
	float cycle = fract(sim_time * mix(0.18, 0.31, hash11(seed + 9.0)) + hash11(seed));
	float life = sin(cycle * 3.14159265);
	float sparse = step(hash11(seed + 41.0), clamp(gate * 0.55, 0.0, 1.0));
	particle_alpha = life * life * gate * sparse * 0.22;

	vec3 center = vec3(xz.x + displacement.x, displacement.y, xz.y + displacement.z);
	center.y += life * mix(0.35, 1.7, storm_mood) + cycle * cycle * 0.3;
	center.xz += (hash21(seed + 73.0) - 0.5) * cycle * mix(0.35, 1.8, storm_mood);
	vec3 center_view = (VIEW_MATRIX * vec4(center, 1.0)).xyz;
	particle_uv = UV * 2.0 - 1.0;
	float size = mix(0.025, 0.18, hash11(seed + 23.0)) * mix(0.6, 1.25, storm_mood);
	vec2 billboard = vec2(particle_uv.x * size, particle_uv.y * size * 2.6);
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
