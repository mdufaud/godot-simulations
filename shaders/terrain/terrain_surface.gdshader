// Multi-material terrain surface over the heightfield texture (rgba: sand,
// water, snow, suspended sediment). The vertex shader displaces a flat grid
// mesh by the SOLID column (sand + snow; COLOR.r masks the skirt ring to the
// floor so the sheet has closed sides). The fragment shader rebuilds normals
// from the height texture so shading resolves finer than the mesh, then
// blends four looks: procedural sand (tone wander, speckle, darker avalanche
// faces, glints), wet sand (darker albedo, lower roughness — pores filled),
// a water film (depth-tinted, turbid with sediment, world-anchored
// micro-normals and sun glint) and snow (white-blue, softened normals,
// cold sparkle). Everything distance-fades to avoid shimmer.
shader_type spatial;
// Normals come from the height texture, not the winding, so culling buys
// nothing and the skirt ring is visible from either side.
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D micro_normal_tex : filter_linear_mipmap, repeat_enable;
uniform float world_size = 4.0;
uniform float grid_n = 512.0;

uniform vec3 color_light : source_color = vec3(0.88, 0.75, 0.53);
uniform vec3 color_dark : source_color = vec3(0.62, 0.46, 0.29);

uniform vec3 water_shallow : source_color = vec3(0.38, 0.60, 0.58);
uniform vec3 water_deep : source_color = vec3(0.06, 0.20, 0.28);
uniform vec3 sediment_tint : source_color = vec3(0.48, 0.37, 0.22);
uniform float micro_normal_strength = 0.14;

uniform vec3 snow_color : source_color = vec3(0.93, 0.95, 0.99);
uniform float snow_softness = 0.65;

// Depth scales where each material look takes over (metres of column).
uniform float water_film_m = 0.006;
uniform float water_pool_m = 0.03;
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
	VERTEX.y = (field.r + field.b) * COLOR.r;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float texel = 1.0 / grid_n;
	float cell = world_size / grid_n;
	// Solid surface: sand + snow. Water never displaces, it shades.
	float solid_l = texture(height_tex, UV - vec2(texel, 0.0)).r
		+ texture(height_tex, UV - vec2(texel, 0.0)).b;
	float solid_r = texture(height_tex, UV + vec2(texel, 0.0)).r
		+ texture(height_tex, UV + vec2(texel, 0.0)).b;
	float solid_d = texture(height_tex, UV - vec2(0.0, texel)).r
		+ texture(height_tex, UV - vec2(0.0, texel)).b;
	float solid_u = texture(height_tex, UV + vec2(0.0, texel)).r
		+ texture(height_tex, UV + vec2(0.0, texel)).b;
	vec3 n_world = normalize(vec3(solid_l - solid_r, 2.0 * cell, solid_d - solid_u));

	vec4 field = texture(height_tex, UV);
	float water = field.g;
	float snow = field.b;
	float sediment = field.a;
	float snow_mask = clamp(snow / snow_blend_m, 0.0, 1.0);
	float wet = clamp(water / water_film_m, 0.0, 1.0) * (1.0 - snow_mask);
	// A film deep enough stops reading as damp sand and starts reading as
	// water. The steep onset keeps the half-blended muddy range brief.
	float pool = smoothstep(0.0, 0.55, water / water_pool_m);

	vec2 g = world_pos.xz;
	// Fade world-anchored grain detail as it drops under a pixel.
	float fw = fwidth(g.x + g.y) * 700.0;
	float detail = 1.0 / (1.0 + fw * fw * 0.15);

	// Micro-relief: two noise octaves bump the normal so close-ups don't look
	// like smooth dough — clumps at ~2 cm, grain-scale rough at ~4 mm. Snow
	// buries the grain; water flattens it.
	float grain = detail * (1.0 - snow_mask) * (1.0 - pool);
	float c1 = vnoise(g * 55.0);
	float c2 = vnoise(g * 260.0);
	float e1 = 0.008;
	float e2 = 0.0018;
	vec2 slope = vec2(
		(vnoise((g + vec2(e1, 0.0)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(e2, 0.0)) * 260.0) - c2,
		(vnoise((g + vec2(0.0, e1)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(0.0, e2)) * 260.0) - c2
	);
	n_world = normalize(n_world + vec3(slope.x, 0.0, slope.y) * 0.9 * grain);

	// Fresh snow softens whatever is under it toward flat.
	n_world = normalize(n_world + vec3(0.0, 1.0, 0.0) * (snow_mask * snow_softness));

	// Water ripples: two world-anchored octaves of the shared ocean micro
	// normal, drifting slowly. Fade with distance like the grain.
	vec2 ripple = vec2(0.0);
	if (pool > 0.001) {
		vec2 m1 = texture(micro_normal_tex, g * 3.1 + TIME * 0.02).xy * 2.0 - 1.0;
		vec2 m2 = texture(micro_normal_tex, g * 11.7 - TIME * 0.035).xy * 2.0 - 1.0;
		ripple = (m1 + m2 * 0.5) * micro_normal_strength * pool * detail;
	}
	n_world = normalize(n_world + vec3(ripple.x, 0.0, ripple.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// --- Albedo ---
	float macro = vnoise(g * 1.7) * 0.6 + vnoise(g * 6.3) * 0.4;
	// Smooth two-octave speckle: same energy as a per-grain hash but no
	// cell-aligned square blocks — hard floor()-hash grains read as pixels.
	float speck = vnoise(g * 620.0) * 0.65 + vnoise(g * 1380.0) * 0.35;
	speck = clamp(0.5 + (speck - 0.5) * 1.7, 0.0, 1.0);
	float tone = 0.55 + 0.30 * (macro - 0.5) + 0.55 * (speck - 0.5) * detail;
	vec3 albedo = mix(color_dark, color_light, clamp(tone, 0.0, 1.0));

	// Freshly slumped faces read darker, like the shaded flank of a dune.
	// Snow casts a much softer shade.
	float steep = 1.0 - n_world.y;
	albedo *= 1.0 - (0.30 - 0.14 * snow_mask) * smoothstep(0.04, 0.35, steep);

	// Wet sand: pores fill, albedo darkens.
	// Wet sand darkens and warms: water matches the grain IOR, killing the
	// bright scattering but keeping the hue.
	albedo = mix(albedo, albedo * vec3(0.40, 0.345, 0.30), wet);

	// Snow cover: cold white, blue-sinking into the speckle for texture.
	vec3 snow_alb = snow_color * (0.92 + 0.08 * macro);
	albedo = mix(albedo, snow_alb, snow_mask);

	// Water pool over the bed: depth-tinted, browned by suspended sediment
	// (much less over snow — meltwater carries little). Meltwater on a snow
	// field reads as bright cold blue, not the dark depth teal of ponds.
	vec3 depth_col = mix(water_shallow, water_deep, pool);
	depth_col = mix(depth_col, sediment_tint,
		clamp(sediment * 9.0, 0.0, 0.6) * (1.0 - snow_mask * 0.8));
	depth_col = mix(depth_col, vec3(0.58, 0.74, 0.86), snow_mask * 0.7);
	albedo = mix(albedo, depth_col, pool);

	ALBEDO = albedo;

	// --- Sparkle: only snow crystals glint. Dry sand had bright dots too,
	// but at game distances they read as white dust specks, not glints — the
	// mottled speckle carries the grain instead.
	float snow_glint = smoothstep(0.87, 0.995, vnoise(g * 1150.0 + vec2(1.93, 8.42)));
	float sparkle = snow_glint * snow_mask * 0.5 * detail;
	ALBEDO += vec3(0.38, 0.39, 0.42) * sparkle;
	ALBEDO += vec3(0.38, 0.39, 0.42) * sparkle * snow_mask
		+ vec3(0.35) * sparkle * (1.0 - snow_mask);

	// --- Roughness ---
	float rough = 0.94;
	rough = mix(rough, 0.35, wet);          // damp sand smooths
	rough = mix(rough, 0.82, snow_mask);    // snow: matte but softer than sand
	rough = mix(rough, 0.08, pool);         // open water glints
	ROUGHNESS = mix(rough, 0.2, sparkle);
	SPECULAR = 0.2 + 0.25 * wet + 0.5 * pool * (1.0 - snow_mask);
}
