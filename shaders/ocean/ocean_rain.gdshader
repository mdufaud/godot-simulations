shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 volume_center = vec3(0.0);
uniform vec3 wind_direction = vec3(1.0, 0.0, 0.0);
uniform vec3 volume_size_m = vec3(56.0, 36.0, 56.0);
uniform float rain_intensity = 0.0;
uniform float storm_mood = 0.0;
uniform float sim_time = 0.0;
uniform float fall_speed_m_s = 9.5;
uniform float shutter_s = 0.075;
uniform float streak_width_m = 0.006;
uniform vec3 rain_color : source_color = vec3(0.62, 0.7, 0.74);

varying vec2 rain_uv;
varying float rain_alpha;

vec3 hash31(float value) {
	return fract(sin(vec3(value * 127.1, value * 311.7, value * 74.7))
		* vec3(43758.5453, 22578.1459, 19642.3490));
}

void vertex() {
	float seed = float(INSTANCE_ID) + 41.0;
	vec3 random = hash31(seed);
	vec3 variation = hash31(seed + 7.0);
	vec3 rain_wind = normalize(vec3(wind_direction.x, 0.0, wind_direction.z) + vec3(1e-5, 0.0, 0.0));
	float speed = fall_speed_m_s * mix(0.8, 1.25, variation.x);
	vec3 velocity = vec3(0.0, -speed, 0.0)
		+ rain_wind * speed * mix(0.08, 0.42, storm_mood);
	// World-anchored drops wrapped into a box around the camera: moving the
	// camera slides the box over the rain instead of dragging the rain along.
	vec3 drop = random * volume_size_m + velocity * sim_time;
	vec3 center = volume_center
		+ mod(drop - volume_center + volume_size_m * 0.5, volume_size_m)
		- volume_size_m * 0.5;
	vec3 to_camera = CAMERA_POSITION_WORLD - center;
	float dist = length(to_camera);
	vec3 view_forward = to_camera / max(dist, 1e-4);
	vec3 streak_axis = normalize(velocity);
	vec3 streak = streak_axis - view_forward * dot(streak_axis, view_forward);
	float foreshortening = length(streak);
	streak /= max(foreshortening, 1e-4);
	vec3 right = normalize(cross(view_forward, streak));
	// Never thinner than ~1.3 px: sub-pixel quads alias into dotted sparkles,
	// so the width is clamped and the lost energy goes into the alpha instead.
	float pixel_m = 2.0 * dist / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float width = streak_width_m * mix(0.7, 1.3, variation.y);
	float drawn_width = max(width, pixel_m * 1.3);
	float half_length = 0.5 * (speed * shutter_s * foreshortening + drawn_width);
	vec2 quad = UV * 2.0 - 1.0;
	vec3 world = center + right * quad.x * drawn_width * 0.5 + streak * quad.y * half_length;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	rain_uv = quad;
	float reach = min(volume_size_m.x, volume_size_m.z) * 0.5;
	rain_alpha = rain_intensity * storm_mood * 0.3 * mix(0.45, 1.0, variation.z)
		* (width / drawn_width)
		* smoothstep(2.0, 7.0, dist) * (1.0 - smoothstep(reach * 0.7, reach, dist));
}

void fragment() {
	float edge = 1.0 - smoothstep(0.2, 1.0, abs(rain_uv.x));
	float tip = 1.0 - smoothstep(0.3, 1.0, abs(rain_uv.y));
	float alpha = edge * tip * rain_alpha;
	if (alpha < 0.003) {
		discard;
	}
	ALBEDO = rain_color;
	ALPHA = alpha;
}
