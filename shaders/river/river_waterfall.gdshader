shader_type spatial;
render_mode cull_disabled;

uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D basin_surface : filter_linear, repeat_disable;
uniform sampler2D fall_surface : filter_linear, repeat_disable;
uniform sampler2D fall_clock : filter_nearest, repeat_disable;
uniform sampler2D fall_boundary : filter_nearest, repeat_disable;
uniform vec4 basin_region;
uniform vec4 fall_grid;
uniform float film_length_m = 1.0;
uniform bool live_enabled = false;
uniform bool free_fall = false;
uniform vec3 across_direction = vec3(1.0, 0.0, 0.0);
uniform float width_m = 6.0;
uniform float inlet_m = 0.3;
uniform float landing_level_m = 0.0;
uniform uint reflection_layer = uint(0);
uniform vec2 reflection_heights_m = vec2(-1.0e6);
uniform float speed_m_s = 0.85;
uniform float foam_amount = 0.65;
uniform float clarity = 0.82;
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);
uniform float simulation_time_s = 0.0;
varying vec3 world_position;
varying vec3 surface_normal;
varying vec4 traits;
varying float activity;

vec4 basin(vec2 point) {
	return textureLod(basin_surface, (point - basin_region.xy) / basin_region.zw, 0.0);
}

float transported_depth(float u, float age_s, float distance_m) {
	if (free_fall) {
		float head = textureLod(fall_clock, vec2(0.5), 0.0).g;
		float row = mod(head - floor(max(age_s, 0.0) * fall_grid.w) + fall_grid.z, fall_grid.z);
		return textureLod(fall_surface, vec2(u, (row + 0.5) / fall_grid.z), 0.0).w;
	}
	float film_end = textureLod(fall_boundary, vec2(u, 0.5), 0.0).y;
	float cell = 0.5 / fall_grid.y;
	float distance = clamp(distance_m, 0.0, max(film_end - 0.3, 0.0));
	return textureLod(fall_surface, vec2(u, clamp(distance / film_length_m, cell, 1.0 - cell)), 0.0).w;
}

void vertex() {
	traits = CUSTOM0;
	vec3 position = VERTEX;
	float time = UV.y;
	if (live_enabled && time < 0.0) {
		vec4 pool = basin(VERTEX.xz);
		if (pool.w > 0.01) position.y = mix(pool.z + 0.01, VERTEX.y, smoothstep(-0.12, 0.0, time));
	}
	if (traits.w > 1.5) {
		vec4 pool = live_enabled ? basin(VERTEX.xz) : vec4(0.0);
		position.y = (pool.w > 0.01 ? pool.z : landing_level_m) + 0.03;
	}
	activity = step(0.001, speed_m_s);
	if (live_enabled) {
		bool apron = traits.w > 1.5;
		float age = apron ? UV2.x - 0.15 : time;
		float distance_m = apron ? 1.0e6 : UV2.x;
		float depth = max(transported_depth(UV.x, age, distance_m), transported_depth(UV.x, age - 0.08, distance_m - 0.4));
		activity = smoothstep(0.0001, 0.003, depth);
	}
	float wobble = textureLod(turbulence_texture, vec2(UV.x * width_m * 0.2, (time - simulation_time_s) * 0.8), 2.0).r - 0.5;
	float attached = clamp(traits.w, 0.0, 1.0);
	float amplitude = mix(0.05, 0.025, attached) * smoothstep(0.05, 0.4, time) * (1.0 - traits.y);
	position += NORMAL * mix(wobble, max(wobble, 0.0), attached) * amplitude;
	surface_normal = NORMAL;
	world_position = position;
	VERTEX = position;
}

void fragment() {
	if ((CAMERA_VISIBLE_LAYERS & reflection_layer) != uint(0) && world_position.y < reflection_heights_m.x) { discard; }
	if ((CAMERA_VISIBLE_LAYERS & (reflection_layer << uint(1))) != uint(0) && world_position.y < reflection_heights_m.y) { discard; }
	float time = UV.y;
	float pool = landing_level_m;
	if (live_enabled) {
		vec4 water = basin(world_position.xz);
		pool = water.w > 0.12 ? water.z : landing_level_m;
	}
	bool apron = traits.w > 1.5;
	float above_pool = time > 0.0 && !apron ? world_position.y - pool : 1.0e6;
	if (above_pool < -0.05 || activity * traits.x < 0.01) { discard; }
	float across_m = UV.x * width_m;
	float speed = UV2.y;
	vec2 base = vec2(across_m * 0.35, (time - simulation_time_s) * 1.4);
	float warp = texture(turbulence_texture, base * vec2(0.45, 0.25)).r - 0.5;
	vec2 uv = base + vec2(warp * 0.2, 0.0);
	float threads = texture(turbulence_texture, vec2(across_m * 1.7, time * 0.15 - simulation_time_s * 0.02)).r;
	float coarse = texture(turbulence_texture, uv * vec2(0.9, 0.5) + vec2(0.37, 0.11)).r;
	float fine = texture(turbulence_texture, uv * vec2(6.0, 0.9) + vec2(0.53, 0.71)).r;
	float density = threads * 0.5 + coarse * 0.3 + fine * 0.2;
	if (apron) {
		vec2 drift = vec2(across_m, (time - simulation_time_s) * speed) + vec2(warp * 0.4, 0.0);
		density = texture(turbulence_texture, drift * 0.45).r * 0.55
			+ texture(turbulence_texture, drift * 1.6 + vec2(0.29, 0.61)).r * 0.45;
	}
	float strength = smoothstep(0.0, 0.5, foam_amount);
	float aeration = smoothstep(0.05, 0.9, time) * mix(0.45, 1.0, smoothstep(1.5, 6.0, speed));
	float impact = max(1.0 - smoothstep(0.0, 0.7, above_pool), traits.z);
	float mask = clamp(apron ? traits.z : max(aeration, impact), 0.0, 1.0) * strength;
	float threshold = apron ? mix(0.9, 0.3, mask) : mix(0.95, 0.4, mask);
	float foam = smoothstep(threshold - 0.15, threshold + 0.1, density);
	vec3 along = normalize(cross(surface_normal, across_direction));
	vec3 normal = normalize(surface_normal + across_direction * (threads - 0.5) * 0.3 + along * (coarse - fine) * 0.2);
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);
	bool back = dot(NORMAL, VIEW) < 0.0;
	if (back) NORMAL = -NORMAL;
	vec3 water_color = mix(vec3(0.11, 0.17, 0.17), deep_color, 0.35 + (1.0 - clarity) * 0.3);
	water_color = mix(water_color, vec3(0.42, 0.48, 0.48), smoothstep(0.45, 0.85, threads) * (0.25 + 0.5 * mask));
	vec3 foam_color = vec3(0.7, 0.75, 0.76) * mix(0.72, 1.05, fine * 0.6 + coarse * 0.4);
	ALBEDO = mix(water_color, foam_color, foam) * (back ? 0.7 : 1.0);
	ROUGHNESS = mix(0.55, 0.85, foam);
	SPECULAR = mix(0.12, 0.06, foam);
	EMISSION = mix(water_color * 0.06, foam_color * 0.04, foam);
	float edge_m = min(UV.x, 1.0 - UV.x) * width_m;
	float erosion = traits.y * (1.0 - smoothstep(0.0, 0.4, edge_m));
	float cover = activity * traits.x * smoothstep(0.0, 0.15, UV2.x + inlet_m) * (1.0 - erosion) * smoothstep(-0.05, 0.12, above_pool);
	ALPHA = apron ? activity * traits.x * foam : clamp(cover + (fine - 0.5) * 0.7, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
