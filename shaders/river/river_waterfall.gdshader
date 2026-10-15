shader_type spatial;
render_mode cull_disabled, depth_draw_always;

// Mesh layout from RiverWaterfallCurtain: UV = (fraction across the crest, seconds since the lip),
// UV2 = (metres past the lip, speed m/s), COLOR.r = film / max_film_m,
// CUSTOM0 = (wet, free edge, impact, attached; -1 on edges tucked into a bank).

group_uniforms look;
uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D streak_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);
uniform float clarity = 0.82;
uniform float foam_amount = 0.65;
uniform float simulation_time_s = 0.0;

group_uniforms geometry;
uniform vec3 across_direction = vec3(1.0, 0.0, 0.0);
uniform float width_m = 6.0;
uniform float max_film_m = 0.8;
uniform float landing_level_m = 0.0;
uniform float speed_m_s = 0.85;
uniform uint reflection_layer = uint(0);
uniform vec2 reflection_heights_m = vec2(-1.0e6);

group_uniforms live_flow;
uniform bool live_enabled = false;
uniform bool free_fall = false;
uniform sampler2D basin_surface : filter_linear, repeat_disable;
uniform sampler2D fall_surface : filter_linear, repeat_disable;
uniform sampler2D fall_clock : filter_nearest, repeat_disable;
uniform sampler2D fall_boundary : filter_nearest, repeat_disable;
uniform vec4 basin_region;
uniform vec4 fall_grid;
uniform float film_length_m = 1.0;
uniform float source_height_m = 6.06;
group_uniforms;

const float STREAKS_PER_M = 0.17;
const float THREADS_PER_M = 0.6;
const float SHEET_DEPTH_M = 0.25;
const float EDGE_FRAY_M = 0.4;
const float BANK_FOAM_M = 0.5;
const float IMPACT_FOAM_M = 0.6;
const float REFRACTION = 0.025;

varying vec3 world_position;
varying vec3 surface_normal;
varying vec4 traits;
varying float activity;
varying float film_m;

vec4 basin(vec2 point) {
	return textureLod(basin_surface, (point - basin_region.xy) / basin_region.zw, 0.0);
}

float pool_height(vec2 point) {
	vec4 water = basin(point);
	return water.w > 0.12 ? water.z : landing_level_m;
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
	film_m = COLOR.r * max_film_m;
	float time = UV.y;
	float attached = clamp(traits.w, 0.0, 1.0);
	vec3 position = VERTEX;
	activity = step(0.001, speed_m_s);
	if (live_enabled) {
		float source = textureLod(fall_boundary, vec2(UV.x, 0.5), 0.0).x;
		float drop = source > 0.0 ? clamp(source - source_height_m, -max_film_m, 0.0) : 0.0;
		vec3 shift = mix(vec3(0.0, drop, 0.0), NORMAL * max(drop, -film_m * 0.8), attached);
		position += shift * (1.0 - attached * smoothstep(0.0, 0.4, time));
		vec4 inlet = basin(VERTEX.xz);
		if (time < 0.0 && inlet.w > 0.01) {
			position.y = mix(inlet.z - 0.01, position.y, smoothstep(-0.12, 0.0, time));
		}
		float depth = max(transported_depth(UV.x, time, UV2.x), transported_depth(UV.x, time - 0.08, UV2.x - 0.4));
		activity = smoothstep(0.0001, 0.003, depth);
	}
	float wobble = textureLod(turbulence_texture, vec2(UV.x * width_m * 0.2, (time - simulation_time_s) * 0.8), 2.0).r - 0.5;
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
	float pool = live_enabled ? pool_height(world_position.xz) : landing_level_m;
	float above_pool_m = time > 0.0 ? world_position.y - pool : 1.0e6;
	float edge_m = min(UV.x, 1.0 - UV.x) * width_m;
	float across_m = UV.x * width_m;
	float flow_s = time - simulation_time_s;
	float fray = texture(turbulence_texture, vec2(across_m * 2.1, flow_s * 1.26) + vec2(0.53, 0.71)).r - 0.5;
	float coverage = activity * traits.x * (1.0 - traits.y * (1.0 - smoothstep(0.0, EDGE_FRAY_M, edge_m)));
	if (coverage < 0.01) { discard; }

	float speed = UV2.y;
	float strength = smoothstep(0.0, 0.5, foam_amount);
	vec3 along = normalize(cross(surface_normal, across_direction));
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - world_position);

	float warp = texture(turbulence_texture, vec2(across_m * 0.16, flow_s * 0.35)).r - 0.5;
	float broad = texture(turbulence_texture, vec2(across_m * 0.1 + warp * 0.03, flow_s * 1.5)).r;
	vec2 near_uv = vec2(across_m * STREAKS_PER_M + warp * 0.04, flow_s);
	float near = texture(streak_texture, near_uv).r;
	vec2 slope = vec2(texture(streak_texture, near_uv + vec2(0.004, 0.0)).r,
		texture(streak_texture, near_uv + vec2(0.0, 0.01)).r) - near;
	float facing = max(abs(dot(to_camera, surface_normal)), 0.3);
	vec2 parallax = vec2(dot(to_camera, across_direction) * STREAKS_PER_M * 1.35,
		dot(to_camera, along) / max(speed, 1.0)) * SHEET_DEPTH_M / facing;
	float deep = texture(streak_texture, vec2(across_m * STREAKS_PER_M * 1.35 + 0.37, flow_s * 1.35 + 0.19) - parallax).r;
	float streaks = max(near * mix(0.6, 1.0, broad), deep * 0.7);

	float column = texture(turbulence_texture, vec2(across_m * 0.08, simulation_time_s * 0.02)).r
		+ (texture(turbulence_texture, vec2(across_m * 0.29 + 0.41, simulation_time_s * 0.04 + 0.3)).r - 0.5) * 0.35;
	float front_s = 0.3 + (column - 0.5) * 0.4;
	float reach_s = time + (streaks - 0.5) * 0.25;
	float aeration = smoothstep(front_s - 0.05, front_s + 0.3, reach_s) * mix(0.55, 1.0, smoothstep(1.5, 6.0, speed));
	float glass = (1.0 - smoothstep(front_s - 0.2, front_s + 0.05, reach_s)) * smoothstep(-0.15, 0.0, time);
	float impact = max(1.0 - smoothstep(0.0, IMPACT_FOAM_M, above_pool_m), traits.z);
	float bank = (1.0 - smoothstep(0.0, BANK_FOAM_M, edge_m)) * (1.0 - traits.y) * smoothstep(0.0, 0.3, time);
	float foam = strength * max(max(
		pow(streaks, 0.8) * aeration * mix(0.55, 1.0, max(aeration, impact) * strength),
		impact * mix(0.75, 1.0, near)),
		max(bank * mix(0.5, 1.0, deep), smoothstep(0.55, 0.95, near) * 0.45 * (1.0 - aeration)));

	vec2 thread_uv = vec2(across_m * THREADS_PER_M + 0.29, flow_s * 1.2);
	float thread = texture(streak_texture, thread_uv).r;
	vec2 thread_slope = vec2(texture(streak_texture, thread_uv + vec2(0.004, 0.0)).r - thread, 0.0);
	vec2 tilt = mix(slope, thread_slope * 1.5, glass) * vec2(0.4, 0.2);
	vec3 normal = normalize(surface_normal + across_direction * ((broad - 0.5) * 0.035 - tilt.x) - along * tilt.y);
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);
	bool back = dot(NORMAL, VIEW) < 0.0;
	if (back) { NORMAL = -NORMAL; }
	float absorption = mix(3.8, 0.32, clarity);
	float path_m = clamp(film_m / max(dot(NORMAL, VIEW), 0.5), 0.1, 0.6);
	vec3 transmittance = exp(-vec3(1.25, 0.72, 0.63) * absorption * path_m);
	vec2 refraction = NORMAL.xy * REFRACTION * smoothstep(0.0, 0.2, film_m);
	vec3 behind = textureLod(screen_texture, clamp(SCREEN_UV + refraction, vec2(0.001), vec2(0.999)), 0.0).rgb;
	float milky = aeration * strength;
	vec3 water_color = mix(vec3(0.11, 0.17, 0.17), deep_color, 0.35 + (1.0 - clarity) * 0.3);
	vec3 scatter = water_color * (vec3(1.0) - transmittance) + vec3(0.18, 0.22, 0.23) * milky;
	vec3 foam_color = vec3(0.86, 0.92, 0.94) * mix(0.85, 1.0, broad);
	ALBEDO = mix(scatter, foam_color, foam) * (back ? 0.85 : 1.0);
	EMISSION = behind * transmittance * (1.0 - foam) * (1.0 - milky * 0.5);
	ROUGHNESS = mix(0.12, 0.75, foam);
	SPECULAR = mix(0.5, 0.2, foam);
	BACKLIGHT = vec3(0.5, 0.6, 0.6) * mix(0.25, 0.8, foam);
	ALPHA = smoothstep(0.25, 0.6, coverage + fray * 0.7 + (streaks - 0.5) * 0.3 * traits.y);
}
