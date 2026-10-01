// Multi-material terrain surface over the heightfield texture (rgba: sand,
// water, snow, suspended sediment). The vertex shader displaces a flat grid
// mesh by the SOLID column (sand + snow; COLOR.r masks the skirt ring to the
// floor so the sheet has closed sides). The fragment shader rebuilds normals
// from the height texture so shading resolves finer than the mesh, then
// blends procedural sand (tone wander, speckle, darker avalanche faces),
// wet sand (darker albedo, lower roughness — pores filled) and snow (white-blue, softened normals,
// cold sparkle). Everything distance-fades to avoid shimmer.
shader_type spatial;
// Normals come from the height texture, not the winding, so culling buys
// nothing and the skirt ring is visible from either side.
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size = 4.0;
uniform float grid_n = 512.0;

uniform vec3 color_light : source_color = vec3(0.88, 0.75, 0.53);
uniform vec3 color_dark : source_color = vec3(0.62, 0.46, 0.29);
uniform bool landscape_materials = false;
uniform bool snow_enabled = true;
uniform float snowline_m = -1.0;
uniform vec3 rock_light : source_color = vec3(0.43, 0.43, 0.40);
uniform vec3 rock_dark : source_color = vec3(0.13, 0.15, 0.14);
uniform vec3 grass_light : source_color = vec3(0.32, 0.39, 0.14);
uniform vec3 grass_dark : source_color = vec3(0.12, 0.21, 0.06);
uniform float rock_slope_lo = 0.08;
uniform float rock_slope_hi = 0.32;

uniform vec3 snow_color : source_color = vec3(0.93, 0.95, 0.99);
uniform float snow_softness = 0.65;

// Depth scales where each material look takes over (metres of column).
uniform float water_film_m = 0.006;
uniform float snow_blend_m = 0.012;

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	vec4 field = texture(height_tex, UV);
	VERTEX.y = (field.r + (snow_enabled ? field.b : 0.0)) * COLOR.r;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float solid_height(vec2 uv) {
	vec4 field = texture(height_tex, uv);
	return field.r + (snow_enabled ? field.b : 0.0);
}

float rock_pattern(vec2 p) {
	return vnoise(p * 2.2) * 0.55 + vnoise(p * 9.7 + vec2(3.7, 8.1)) * 0.45;
}

void fragment() {
	float texel = 1.0 / grid_n;
	float cell = world_size / grid_n;
	// Solid surface: sand + snow. Open water uses a separate surface.
	float solid_l = solid_height(UV - vec2(texel, 0.0));
	float solid_r = solid_height(UV + vec2(texel, 0.0));
	float solid_d = solid_height(UV - vec2(0.0, texel));
	float solid_u = solid_height(UV + vec2(0.0, texel));
	vec3 n_world = normalize(vec3(solid_l - solid_r, 2.0 * cell, solid_d - solid_u));
	vec3 geometric_normal = n_world;
	float steep = 1.0 - n_world.y;
	float rock_mask = landscape_materials ? smoothstep(rock_slope_lo, rock_slope_hi, steep) : 0.0;
	float grass_mask = landscape_materials ? (1.0 - rock_mask)
		* (snow_enabled ? 1.0 - smoothstep(snowline_m - 0.05, snowline_m, world_pos.y) : 1.0) : 0.0;

	vec4 field = texture(height_tex, UV);
	float water = field.g;
	float snow = snow_enabled ? field.b : 0.0;
	float snow_mask = clamp(snow / snow_blend_m, 0.0, 1.0);
	float wet = clamp(water / water_film_m, 0.0, 1.0) * (1.0 - snow_mask);

	vec3 landscape_pos = world_pos * (32.0 / world_size);
	vec2 g = landscape_materials ? landscape_pos.xz : world_pos.xz;
	// Fade world-anchored grain detail as it drops under a pixel.
	float fw = fwidth(g.x + g.y) * (landscape_materials ? 80.0 : 700.0);
	float detail = 1.0 / (1.0 + fw * fw * 0.15);

	// Micro-relief: two noise octaves bump the normal so close-ups don't look
	// like smooth dough — clumps at ~2 cm, grain-scale rough at ~4 mm. Snow
	// buries the grain; water flattens it.
	float grain = detail * (1.0 - snow_mask) * (1.0 - wet);
	float c1 = vnoise(g * 55.0);
	float c2 = vnoise(g * 260.0);
	float e1 = 0.008;
	float e2 = 0.0018;
	vec2 slope = vec2(
		(vnoise((g + vec2(e1, 0.0)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(e2, 0.0)) * 260.0) - c2,
		(vnoise((g + vec2(0.0, e1)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(0.0, e2)) * 260.0) - c2
	);
	n_world = normalize(n_world + vec3(slope.x, 0.0, slope.y) * 0.9 * grain);
	if (landscape_materials) {
		float rock_noise = vnoise(g * 17.0 + vec2(landscape_pos.y * 11.0));
		vec2 rock_slope = vec2(
			vnoise((g + vec2(0.02, 0.0)) * 17.0 + vec2(landscape_pos.y * 11.0)) - rock_noise,
			vnoise((g + vec2(0.0, 0.02)) * 17.0 + vec2(landscape_pos.y * 11.0)) - rock_noise
		);
		n_world = normalize(n_world + vec3(rock_slope.x, 0.0, rock_slope.y)
			* rock_mask * 1.2 * grain);
	}

	// Fresh snow softens whatever is under it toward flat.
	n_world = normalize(n_world + vec3(0.0, 1.0, 0.0) * (snow_mask * snow_softness));

	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// --- Albedo ---
	float macro = vnoise(g * 1.7) * 0.6 + vnoise(g * 6.3) * 0.4;
	// Smooth two-octave speckle: same energy as a per-grain hash but no
	// cell-aligned square blocks — hard floor()-hash grains read as pixels.
	float speck = vnoise(g * 620.0) * 0.65 + vnoise(g * 1380.0) * 0.35;
	speck = clamp(0.5 + (speck - 0.5) * 1.7, 0.0, 1.0);
	float tone = 0.55 + 0.30 * (macro - 0.5) + 0.55 * (speck - 0.5) * detail;
	vec3 albedo = mix(color_dark, color_light, clamp(tone, 0.0, 1.0));
	if (landscape_materials) {
		vec3 weights = pow(abs(geometric_normal), vec3(4.0));
		weights /= weights.x + weights.y + weights.z;
		float rock_noise = dot(vec3(rock_pattern(landscape_pos.zy),
			rock_pattern(landscape_pos.xz), rock_pattern(landscape_pos.xy)), weights);
		vec3 rock_albedo = mix(rock_dark, rock_light, clamp(rock_noise * 1.6 - 0.3, 0.0, 1.0));
		float patches = vnoise(g * 0.35) * 0.5 + vnoise(g * 1.4) * 0.3 + macro * 0.2;
		vec3 grass_albedo = mix(grass_dark, grass_light, clamp(patches * 1.5 - 0.2, 0.0, 1.0));
		albedo = mix(rock_albedo, grass_albedo, grass_mask);
	}

	// Freshly slumped faces read darker, like the shaded flank of a dune.
	// Snow casts a much softer shade.
	float shade_steep = landscape_materials ? steep : 1.0 - n_world.y;
	albedo *= 1.0 - (0.30 - 0.14 * snow_mask) * smoothstep(0.04, 0.35, shade_steep);

	// Wet sand: pores fill, albedo darkens.
	// Wet sand darkens and warms: water matches the grain IOR, killing the
	// bright scattering but keeping the hue.
	albedo = mix(albedo, albedo * (landscape_materials ? vec3(0.55, 0.60, 0.50) : vec3(0.40, 0.345, 0.30)), wet);

	// Snow cover: cold white, blue-sinking into the speckle for texture.
	vec3 snow_alb = snow_color * (0.92 + 0.08 * macro);
	albedo = mix(albedo, snow_alb, snow_mask);

	ALBEDO = albedo;

	// --- Sparkle: only snow crystals glint. Dry sand had bright dots too,
	// but at game distances they read as white dust specks, not glints — the
	// mottled speckle carries the grain instead.
	float snow_glint = smoothstep(0.87, 0.995, vnoise(g * 1150.0 + vec2(1.93, 8.42)));
	float sparkle = snow_glint * snow_mask * 0.5 * detail;
	ALBEDO += vec3(0.38, 0.39, 0.42) * sparkle;

	// --- Roughness ---
	float rough = 0.94;
	rough = mix(rough, 0.98, rock_mask);
	rough = mix(rough, 0.35, wet);          // damp sand smooths
	rough = mix(rough, 0.82, snow_mask);    // snow: matte but softer than sand
	ROUGHNESS = mix(rough, 0.2, sparkle);
	SPECULAR = 0.2 + 0.25 * wet;
}
