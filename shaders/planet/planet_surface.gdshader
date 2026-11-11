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

uniform float bump_strength = 0.0;
uniform float biome_variation = 0.0;
uniform vec3 col_biome : source_color = vec3(0.6, 0.52, 0.24);
// Both thresholds switch their effect off at values above 1.
uniform float snow_height = 2.0;
uniform float polar_cap = 2.0;
uniform vec3 col_snow : source_color = vec3(0.93, 0.95, 0.97);
uniform float crack_strength = 0.0;
uniform vec3 col_crack : source_color = vec3(0.1, 0.28, 0.5);
uniform float specular_strength = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float ridge(float value) {
	return max(1.0 - abs(value), 0.0);
}

float bump_height(vec3 pos) {
	return (ridge(snoise(pos * 0.22))) + 0.5 * (ridge(snoise(pos * 0.5)))
			+ 0.22 * snoise(pos * 1.1);
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

	vec3 lit_normal = simple_normal;
	if (bump_strength > 0.0) {
		vec3 tangent = normalize(cross(simple_normal, vec3(0.31, 0.87, 0.38)));
		vec3 bitangent = cross(simple_normal, tangent);
		float here = bump_height(detail_pos);
		vec3 gradient = tangent * (bump_height(detail_pos + tangent * 0.2) - here)
				+ bitangent * (bump_height(detail_pos + bitangent * 0.2) - here);
		lit_normal = normalize(simple_normal - gradient * (bump_strength * 2.2));
	}

	vec3 shading = vec3(dot(normalize(sun_direction), lit_normal) * 0.5 + 0.5);
	shading += col_ambient;
	if (terrain_style == 0) {
		shading = vec3(0.12 + 0.88 * max(dot(normalize(sun_direction), lit_normal), 0.0)) + col_ambient * 0.5;
	}
	shading = pow(max(shading, vec3(0.0)), vec3(shade_pow));

	float height_detail = terrain_style == 1 ? noise * planet_radius / reference_radius : 0.0;
	float height_t = (length(world_pos) - height_min + height_detail) / max(height_max - height_min, 0.001);
	height_t = clamp(height_t, 0.0, 1.0);
	float height_raw = height_t;
	// Posterising the gradient is what produces the terraced look.
	height_t = float(int(height_t * height_bands)) / height_bands;

	// 1 where the surface faces straight out from the core, 0 on a vertical cliff.
	float flatness = dot(normalize(world_pos), detail_normal);
	float flat_t = flat_blend > 0.0
		? smoothstep(-flat_blend, flat_blend, flatness - flat_threshold)
		: step(flat_threshold, flatness);

	vec3 c_flat = mix(col_flat_deep, col_flat, height_t);
	vec3 c_steep = mix(col_steep_deep, col_steep, height_t);
	vec3 surface = mix(c_flat, c_steep, 1.0 - flat_t);
	if (biome_variation > 0.0) {
		float biome = snoise(detail_pos * 0.07 + vec3(13.0)) * 0.6 + snoise(detail_pos * 0.19) * 0.4;
		surface = mix(surface, col_biome * (0.6 + 0.4 * height_t),
				smoothstep(-0.1, 0.5, biome) * biome_variation * flat_t);
	}
	if (crack_strength > 0.0) {
		float crack_warp = snoise(detail_pos * 0.12);
		float cracks = pow(ridge(snoise(detail_pos * 0.3 + vec3(crack_warp * 1.2))), 24.0)
				+ 0.6 * pow(ridge(snoise(detail_pos * 0.75 + vec3(crack_warp))), 30.0);
		surface = mix(surface, col_crack, clamp(cracks, 0.0, 1.0) * crack_strength * flat_t);
	}
	float latitude = abs(normalize(world_pos).y) + snoise(detail_pos * 0.15) * 0.06;
	float snow = max(
			smoothstep(snow_height - 0.08, snow_height + 0.04, height_raw + snoise(detail_pos * 0.3) * 0.05),
			smoothstep(polar_cap - 0.05, polar_cap + 0.05, latitude));
	snow *= smoothstep(flat_threshold - 0.3, flat_threshold - 0.05, flatness);
	surface = mix(surface, col_snow, snow);
	ALBEDO = surface * shading;
	if (specular_strength > 0.0) {
		vec3 sun = normalize(sun_direction);
		vec3 half_vector = normalize(sun + normalize(CAMERA_POSITION_WORLD - world_pos));
		ALBEDO += pow(max(dot(lit_normal, half_vector), 0.0), 60.0) * specular_strength
				* smoothstep(0.0, 0.2, dot(sun, simple_normal));
	}
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
		// Core: dark crust plates drifting over bright convection seams.
		float cells = snoise(detail_pos * 0.32 + vec3(TIME * 0.035, 0.0, TIME * 0.02));
		float seam_noise = snoise(detail_pos * 0.6 + vec3(cells * 0.7, TIME * 0.05, 0.0));
		float seams = pow(ridge(seam_noise), 5.0);
		float plates = smoothstep(-0.35, 0.45, cells);
		vec3 core_color = mix(col_core * vec3(0.5, 0.22, 0.12), col_core, plates);
		core_color = mix(core_color, vec3(1.0, 0.86, 0.42), seams);
		float core_power = mix(0.10, 0.26, plates) + seams * 0.55;
		// Mantle faces: cracks that fill with melt towards the core.
		float cracks = pow(ridge(snoise(detail_pos * 0.42 + vec3(7.3, 1.9, TIME * 0.03))), 9.0);
		float melt = cracks * smoothstep(0.05, 0.75, heat) * 1.6 + heat * heat * 0.16;
		vec3 mantle_emission = mix(col_core * vec3(1.0, 0.45, 0.3), col_core, cracks) * melt;
		emission += mix(mantle_emission, core_color * core_power, core) * core_emission * pulse * mantle;
		// Core light on every face turned towards it, inner crust walls included.
		float facing = max(dot(simple_normal, -normalize(world_pos)), 0.0);
		float reach = core_fraction / max(depth, core_fraction);
		emission += col_core * facing * reach * reach * core_emission * 0.17 * strata * (1.0 - core);
	}
	if (volcano_count > 0) {
		float radial = length(world_pos) / planet_radius;
		vec3 radial_direction = normalize(world_pos);
		float scorch = 0.0;
		for (int volcano_index = 0; volcano_index < volcano_count; volcano_index++) {
			vec4 volcano = volcano_centres[volcano_index];
			vec3 axis = normalize(volcano.xyz);
			float channel;
			vec4 mountain = volcano_sample(radial_direction, volcano, volcano_size_ratio, volcano_height_ratio,
					radial, volcano_floor_fraction, volcano_crater_bottom_ratio, volcano_crater_top_ratio, channel);
			float above = radial - volcano.w;
			float massif = (1.0 - smoothstep(0.85, 1.08, mountain.y))
					* smoothstep(0.006, 0.03, above);
			float elevation = clamp(above / volcano_height_ratio, 0.0, 1.0);
			vec3 crater_coords = (radial_direction - axis) / max(volcano_size_ratio, 0.001);
			// Ash fan around the cone, layered basalt on it, sulphur near the rim.
			scorch = max(scorch, 1.0 - smoothstep(0.7, 1.9, length(crater_coords)
					+ snoise(crater_coords * 2.5) * 0.25));
			float layers = 0.82 + 0.18 * sin(elevation * 46.0 + snoise(crater_coords * 3.0) * 2.5);
			vec3 basalt = mix(col_steep_deep, col_steep, elevation) * layers;
			float rim_distance = max(mountain.w / max(volcano_size_ratio, 0.001), 0.0);
			float sulphur = exp(-rim_distance * 7.0) * smoothstep(0.55, 0.95, elevation)
					* (0.5 + 0.5 * snoise(crater_coords * 11.0));
			basalt = mix(basalt, vec3(0.62, 0.50, 0.16), sulphur * 0.55);
			ALBEDO = mix(ALBEDO, basalt * shading, massif);

			float angular_edge = max(fwidth(mountain.w), 0.001);
			float inside_crater = 1.0 - smoothstep(-angular_edge, angular_edge, mountain.w);
			float floor_edge = max(fwidth(radial) * 2.0, 0.003);
			float on_floor = 1.0 - smoothstep(0.012, 0.012 + floor_edge, abs(radial - mountain.z));
			float lava_mask = inside_crater * on_floor;
			// Lake: cooling plates split by bright seams that drift outwards.
			float drift = snoise(crater_coords * 5.0 + vec3(0.0, TIME * 0.05, 0.0));
			float seam = ridge(snoise(crater_coords * 13.0 + vec3(drift * 0.8, 0.0, TIME * 0.07)));
			seam = pow(seam, 6.0);
			float churn = smoothstep(0.1, 0.9, 0.5 + 0.5 * snoise(crater_coords * 6.0 - vec3(TIME * 0.09)));
			vec3 lake = mix(vec3(0.20, 0.022, 0.006), vec3(0.95, 0.24, 0.03), churn);
			lake = mix(lake, vec3(1.0, 0.80, 0.30), seam);
			float lake_power = 0.12 + 0.3 * churn + seam * lava_glow * 0.3;
			ALBEDO = mix(ALBEDO, vec3(0.075, 0.035, 0.022), lava_mask);
			emission += lake * lake_power * lava_mask * volcano_activity;

			// Rivers down the ravines: bright at the rim, crusting over towards the foot.
			float reach = mix(0.35, 1.0, volcano_activity);
			float along = mountain.y / (reach * (0.55 + 0.45 * snoise(normalize(crater_coords + vec3(1e-4)) * 2.2 + axis * 5.0)));
			float river = smoothstep(0.52, 0.78, channel) * (1.0 - smoothstep(0.75, 1.0, along))
					* (1.0 - inside_crater) * smoothstep(0.004, 0.02, above);
			float surge = 0.6 + 0.4 * sin(mountain.y * 26.0 - TIME * 1.6
					+ snoise(crater_coords * 4.0) * 4.0);
			float cool = smoothstep(0.15, 0.95, along);
			vec3 river_color = mix(vec3(1.0, 0.62, 0.16), vec3(0.75, 0.07, 0.01), cool);
			float core_line = smoothstep(0.8, 0.98, channel);
			ALBEDO = mix(ALBEDO, vec3(0.06, 0.03, 0.02), river * volcano_activity);
			emission += river_color * river * surge * volcano_activity
					* mix(0.5, 0.18, cool) * (1.0 + core_line * lava_glow * 0.45);
			// Heat spilling over the rim onto the rock.
			emission += vec3(1.0, 0.22, 0.03) * exp(-rim_distance * 9.0) * massif
					* (1.0 - inside_crater) * 0.35 * volcano_activity;
		}
		// Scorched ground, and fissures glowing through the lowlands near the cones.
		float outside = 1.0 - clamp(length(emission) * 4.0, 0.0, 1.0);
		ALBEDO *= mix(1.0, 0.62, scorch * outside);
		float fissure_noise = snoise(detail_pos * 0.16 + vec3(snoise(detail_pos * 0.07) * 1.5));
		float fissure = pow(ridge(fissure_noise), 30.0)
				* smoothstep(-0.1, 0.5, snoise(detail_pos * 0.045 + vec3(9.1, 3.3, 5.7)));
		float lowland = 1.0 - smoothstep(0.2, 0.55, height_raw);
		float breathe = 0.7 + 0.3 * snoise(detail_pos * 0.1 + vec3(0.0, TIME * 0.2, 0.0));
		emission += mix(vec3(0.8, 0.09, 0.01), vec3(1.0, 0.55, 0.12), fissure) * fissure * lowland
				* outside * breathe * volcano_activity * (0.35 + lava_glow * 0.18);
	}
	ALBEDO += emission;
}
