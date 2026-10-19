// Planet surface shading. Port of MarchingCubesDraw.shader from SebLague/Fluid-Planet.
// No textures and no triplanar: the colour is a quantised height band crossed with a
// flat/steep threshold, lit by a half-lambert against a single sun direction.
// Unshaded on purpose -- the original does its own lighting and samples no shadow map.
shader_type spatial;
render_mode unshaded;

#include "res://shaders/planet/simplex_noise.gdshaderinc"
#include "res://shaders/planet/volcano_shape.gdshaderinc"

uniform vec3 sun_direction = vec3(0.5, 0.4, 0.75);

uniform vec3 col_flat : source_color = vec3(0.670, 0.465, 0.281);
uniform vec3 col_flat_deep : source_color = vec3(0.434, 0.180, 0.166);
uniform vec3 col_steep : source_color = vec3(0.368, 0.270, 0.227);
uniform vec3 col_steep_deep : source_color = vec3(0.208, 0.153, 0.179);
uniform vec3 col_ambient : source_color = vec3(0.500, 0.390, 0.389);

uniform float shade_pow = 1.5;
uniform float flat_threshold = 0.76;
uniform float flat_blend = 0.01;
// Height range the colour gradient spans, and how many discrete bands it is cut into.
uniform float height_min = 16.2;
uniform float height_max = 28.3;
uniform float height_bands = 5.2;
uniform float planet_radius = 23.0;
uniform float reference_radius = 23.0;
uniform int terrain_style = 0;
uniform bool interior_enabled = false;
uniform float core_fraction = 0.32;
uniform float crust_fraction = 0.82;
uniform float core_emission = 3.0;
uniform vec3 col_mantle : source_color = vec3(0.34, 0.075, 0.025);
uniform vec3 col_core : source_color = vec3(1.0, 0.34, 0.035);
uniform int volcano_count = 0;
uniform vec4 volcano_centres[8];
uniform float volcano_size_ratio = 0.28;
uniform float volcano_height_ratio = 0.18;
uniform float volcano_activity = 1.0;
uniform float lava_glow = 4.0;
uniform float volcano_floor_fraction;
uniform float volcano_crater_bottom_ratio;
uniform float volcano_crater_top_ratio;

// Detail noise perturbing both the height band and the surface normal.
uniform int detail_octaves : hint_range(0, 8) = 8;
uniform float detail_scale = 1.0;
uniform float detail_persistence = 0.11;
uniform float detail_lacunarity = 2.0;
uniform float detail_offset = 0.82;
uniform float detail_strength = 0.25;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 detail_pos = world_pos * reference_radius / planet_radius;
	// continent_noise gets detail_scale as both the position multiplier and the base
	// frequency, exactly as in the original -- the squared frequency is part of the look.
	float noise = 0.0;
	if (detail_octaves > 0) {
		noise = (continent_noise(detail_pos * detail_scale, detail_octaves,
				detail_persistence, detail_lacunarity, detail_scale) - detail_offset) * detail_strength;
	}

	vec3 simple_normal = normalize(world_normal);
	// Adding a scalar to a vector is deliberate: a cheap directional wobble.
	vec3 detail_normal = terrain_style == 1 ? normalize(world_normal + noise) : simple_normal;

	vec3 shading = vec3(dot(normalize(sun_direction), simple_normal) * 0.5 + 0.5);
	shading += col_ambient;
	if (terrain_style == 0) {
		shading = vec3(0.12 + 0.88 * max(dot(normalize(sun_direction), simple_normal), 0.0)) + col_ambient * 0.5;
	}
	shading = pow(max(shading, vec3(0.0)), vec3(shade_pow));

	float height_detail = terrain_style == 1 ? noise * planet_radius / reference_radius : 0.0;
	float height_t = (length(world_pos) - height_min + height_detail) / max(height_max - height_min, 0.001);
	height_t = clamp(height_t, 0.0, 1.0);
	// Posterising the gradient is what produces the terraced look.
	height_t = float(int(height_t * height_bands)) / height_bands;

	// 1 where the surface faces straight out from the core, 0 on a vertical cliff.
	float flatness = dot(normalize(world_pos), detail_normal);
	float flat_t = flat_blend > 0.0
		? smoothstep(-flat_blend, flat_blend, flatness - flat_threshold)
		: step(flat_threshold, flatness);

	vec3 c_flat = mix(col_flat_deep, col_flat, height_t);
	vec3 c_steep = mix(col_steep_deep, col_steep, height_t);
	ALBEDO = mix(c_flat, c_steep, 1.0 - flat_t) * shading;
	if (terrain_style == 0) {
		ALBEDO *= 1.0 + noise * 0.08;
	}
	vec3 emission = vec3(0.0);
	if (interior_enabled) {
		float depth = length(world_pos) / planet_radius;
		float mantle = 1.0 - smoothstep(crust_fraction - 0.025, crust_fraction + 0.025, depth);
		float core = 1.0 - smoothstep(core_fraction + 0.01, core_fraction + 0.05, depth);
		float strata = 0.75 + 0.25 * sin(depth * 110.0 + snoise(detail_pos * 0.35) * 2.0);
		float heat = clamp((crust_fraction - depth) / (crust_fraction - core_fraction), 0.0, 1.0);
		vec3 inner_color = mix(col_mantle * strata, col_core * 0.35, core);
		ALBEDO = mix(ALBEDO, inner_color * shading, mantle);
		float pulse = 0.92 + 0.08 * snoise(detail_pos * 0.2 + vec3(0.0, TIME * 0.15, 0.0));
		float molten = 0.5 + 0.5 * snoise(detail_pos * 0.65 + vec3(TIME * 0.06, 0.0, 0.0));
		vec3 hot_color = mix(col_core, vec3(1.0, 0.85, 0.35), core * smoothstep(0.3, 0.85, molten));
		emission += hot_color * core_emission * pulse * mantle * mix(heat * heat * 0.22, 1.0, core);
	}
	if (volcano_count > 0) {
		float radial = length(world_pos) / planet_radius;
		vec3 radial_direction = normalize(world_pos);
		for (int volcano_index = 0; volcano_index < volcano_count; volcano_index++) {
			vec4 volcano = volcano_centres[volcano_index];
			vec3 axis = normalize(volcano.xyz);
			vec4 mountain = volcano_sample(radial_direction, volcano, volcano_size_ratio, volcano_height_ratio,
					radial, volcano_floor_fraction, volcano_crater_bottom_ratio, volcano_crater_top_ratio);
			float massif = (1.0 - smoothstep(0.85, 1.08, mountain.y))
					* smoothstep(0.006, 0.03, radial - volcano.w);
			float elevation = clamp((radial - volcano.w) / volcano_height_ratio, 0.0, 1.0);
			vec3 basalt = mix(col_steep_deep, col_steep, elevation);
			ALBEDO = mix(ALBEDO, basalt * shading, massif);
			float angular_edge = max(fwidth(mountain.w), 0.001);
			float inside_crater = 1.0 - smoothstep(-angular_edge, angular_edge, mountain.w);
			float floor_edge = max(fwidth(radial) * 2.0, 0.003);
			float on_floor = 1.0 - smoothstep(0.012, 0.012 + floor_edge, abs(radial - mountain.z));
			float lava_mask = inside_crater * on_floor;
			vec3 crater_coords = (radial_direction - axis) / max(volcano_size_ratio, 0.001);
			float flow_noise = snoise(crater_coords * 19.0 + vec3(0.0, TIME * 0.12, TIME * 0.035));
			float channels = 0.5 + 0.5 * sin(dot(crater_coords, vec3(24.0, 31.0, 18.0))
					+ flow_noise * 5.0 - TIME * 1.4);
			float heat = smoothstep(0.25, 0.72, flow_noise * 0.4 + channels * 0.6);
			vec3 molten = mix(vec3(0.72, 0.075, 0.012), vec3(1.0, 0.76, 0.22), heat);
			ALBEDO = mix(ALBEDO, vec3(0.075, 0.035, 0.022), lava_mask * (1.0 - volcano_activity));
			ALBEDO = mix(ALBEDO, molten * shading, lava_mask * volcano_activity);
			emission += molten * lava_mask * volcano_activity * lava_glow;
		}
	}
	ALBEDO += emission;
}
