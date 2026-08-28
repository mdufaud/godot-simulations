shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#define GRID_X 192
#define GRID_Z 80

uniform vec3 volume_center = vec3(0.0);
uniform vec3 wind_direction = vec3(1.0, 0.0, 0.0);
uniform float volume_width = 180.0;
uniform float volume_depth = 140.0;
uniform float volume_height = 72.0;
uniform float rain_intensity = 0.0;
uniform float storm_mood = 0.0;
uniform float sim_time = 0.0;
uniform float streak_length = 0.95;
uniform float streak_width = 0.012;
uniform vec3 rain_color : source_color = vec3(0.58, 0.68, 0.7);

varying vec2 rain_uv;
varying float rain_alpha;

float hash11(float value) {
	return fract(sin(value * 127.1) * 43758.5453);
}

vec2 hash21(float value) {
	return fract(sin(vec2(value * 127.1, value * 311.7))
		* vec2(43758.5453, 22578.1459));
}

void vertex() {
	int index = int(INSTANCE_ID);
	int ix = index % GRID_X;
	int iz = index / GRID_X;
	float seed = float(index) + 41.0;
	vec2 jitter = hash21(seed) - 0.5;
	vec2 cell = (vec2(float(ix), float(iz)) + 0.5)
		/ vec2(float(GRID_X), float(GRID_Z)) - 0.5;
	vec2 xz = volume_center.xz + cell * vec2(volume_width, volume_depth)
		+ jitter * vec2(volume_width / float(GRID_X), volume_depth / float(GRID_Z));
	float speed = mix(0.78, 1.28, hash11(seed + 7.0));
	float phase = fract(hash11(seed + 13.0) + sim_time * speed / volume_height);
	float age = phase * volume_height;
	vec3 rain_wind = normalize(vec3(wind_direction.x, 0.0, wind_direction.z));
	vec3 center = vec3(xz.x, volume_center.y + volume_height * 0.5 - age, xz.y);
	center += rain_wind * age * mix(0.04, 0.16, storm_mood);
	vec3 view_forward = normalize(CAMERA_POSITION_WORLD - center);
	vec3 streak_axis = normalize(vec3(rain_wind.x * 0.14, -1.0, rain_wind.z * 0.14));
	vec3 streak = streak_axis - view_forward * dot(streak_axis, view_forward);
	streak = normalize(streak);
	vec3 right = normalize(cross(view_forward, streak));
	float width = streak_width * mix(0.65, 1.35, hash11(seed + 23.0));
	float length = streak_length * mix(0.65, 1.55, hash11(seed + 31.0));
	vec2 quad = UV * 2.0 - 1.0;
	vec3 world = center + right * quad.x * width + streak * quad.y * length;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	rain_uv = quad;
	rain_alpha = rain_intensity * storm_mood
		* mix(0.35, 1.0, hash11(seed + 53.0));
}

void fragment() {
	float edge = 1.0 - smoothstep(0.42, 1.0, abs(rain_uv.x));
	float tip = 1.0 - smoothstep(0.65, 1.0, abs(rain_uv.y));
    float alpha = edge * tip * rain_alpha * 0.28;
	if (alpha < 0.004) {
		discard;
	}
	ALBEDO = rain_color;
	ALPHA = alpha;
}
