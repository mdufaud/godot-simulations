// FFT ocean surface. Displacement/normal/foam come from OceanSolver's compute
// pipeline through Texture2DArrayRD (one layer per cascade). Lighting model
// follows the Atlas GDC-2019 talk (GGX + wave-flank SSS), filtering mixes
// bicubic B-spline (magnified, fights pixelation) with bilinear (minified).
// Screen-space refraction is depth-guarded: a refracted sample landing in
// front of the surface falls back to the unrefracted one (anti-ghosting fix).

shader_type spatial;
// Reading hint_screen_texture/hint_depth_texture moves this material into the
// transparent pass, which does not write depth by default: waves stopped
// occluding each other (horizon and other waves visible through every crest).
// depth_draw_always restores self-occlusion; the depth_texture we sample only
// holds the opaque pass, so the refraction guard is unaffected.
render_mode world_vertex_coords, cull_disabled, shadows_disabled, depth_draw_always;

#define REFLECTANCE 0.02
#define MAX_CASCADES 3

uniform vec4 water_color : source_color = vec4(0.013, 0.062, 0.098, 1.0);
uniform vec4 foam_color : source_color = vec4(0.71, 0.78, 0.81, 1.0);
uniform float roughness_base : hint_range(0.0, 1.0) = 0.2;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float foam_strength : hint_range(0.0, 3.0) = 1.0;
uniform float sss_strength : hint_range(0.0, 3.0) = 1.0;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec2 wind_direction = vec2(0.0, 1.0);
uniform float sun_disk_radius = 0.00436;
uniform float sun_path_width = 0.009;
uniform float sun_glitter_strength = 0.7;
uniform float sky_reflection_strength = 0.75;
uniform float storm_mood = 0.15;
uniform float clipmap_cell = 0.25;
uniform float clipmap_half_extent = 8.0;
uniform float clipmap_ring_levels = 8.0;
uniform vec3 cascade_wavelengths = vec3(48.0, 7.5, 0.72);
uniform int debug_view = 0;
uniform int geometry_cascade = -1;
uniform bool foam_feedback_enabled = true;
uniform int num_cascades = 3;
uniform vec4 map_scales[MAX_CASCADES]; // xy = uv scale (1/tile), z = displacement scale, w = normal scale
uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform sampler2DArray normals : filter_linear, repeat_enable;
uniform sampler2DArray derivatives : filter_linear, repeat_enable;
uniform bool fft_surface = true;
// Camera-centred near-field foam coverage. Each layer has its own domain and
// the layers are blended radially so the coverage remains world anchored.
uniform sampler2DArray foam_near_a : filter_linear_mipmap, repeat_disable;
uniform sampler2DArray foam_near_b : filter_linear_mipmap, repeat_disable;
uniform vec2 foam_near_center = vec2(0.0);
uniform vec3 foam_domains = vec3(256.0, 1024.0, 4096.0);
uniform float foam_near_index = 0.0;
uniform bool foam_near_enabled = false;
// Locally generated seamless detail used by shore and interaction foam.
uniform sampler2D foam_detail : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D micro_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec2 micro_normal_scales = vec2(0.085, 0.23);
uniform float micro_normal_strength = 0.42;
uniform float micro_normal_fade_start = 70.0;
uniform float micro_normal_fade_end = 360.0;
uniform float detail_distance_m = 1500.0;
uniform sampler2D cloud_reflection : filter_linear, repeat_disable, hint_default_black;
uniform bool cloud_reflection_enabled = true;
uniform vec3 sky_zenith : source_color = vec3(0.055, 0.18, 0.43);
uniform vec3 sky_horizon : source_color = vec3(0.95, 0.43, 0.18);
// P0-C.3: exponential aerial convergence of the far water toward the sky
// (per look; 6e-4 overcast, ~2.5e-4 tropical, 1/m).
uniform float aerial_density = 0.00025;
uniform sampler2D interaction_foam : filter_linear, repeat_disable, hint_default_black;
uniform vec2 interaction_center = vec2(0.0);
uniform float interaction_size = 128.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength = 0.05;
uniform vec4 color_shallow : source_color = vec4(0.1, 0.32, 0.36, 1.0);
uniform float beers_law = 0.35;
// Which side of the interface the viewer is on. Driven by the controller's
// water-height probe: FRONT_FACING can NOT answer this, see fragment().
uniform bool camera_underwater = false;

varying vec2 world_uv;
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float crest_factor;
// P3-A: crest signal summed over the two simulated cascades (0.65/0.35) —
// subsurface scattering follows every breaking crest, not one cascade's.
varying float sss_crest_factor;
varying float glitter_factor;
varying float filtered_roughness;
varying vec3 geometry_weights;
uniform vec3 cascade_slope_variance = vec3(0.0);

float cascade_wavelength(int index) {
	return index == 0 ? cascade_wavelengths.x
		: (index == 1 ? cascade_wavelengths.y : cascade_wavelengths.z);
}

void vertex() {
	// Geomorph (GPU Gems 2 ch. 2): the outer 30% of every clipmap level slides
	// its odd vertices onto the next-coarser lattice, so both sides of each 2:1
	// boundary sample the displacement at identical world positions and cracks
	// are zero by construction. Distance fades alone cannot do this: metre-tall
	// gaps opened wherever storm swell met coarse cells, rendering as dark
	// triangular fins.
	vec2 mesh_center = MODEL_MATRIX[3].xz;
	vec2 p = VERTEX.xz - mesh_center;
	float cheb = max(abs(p.x), abs(p.y));
	float k = clamp(ceil(log2(max(cheb, 1.0) / clipmap_half_extent) - 0.001),
		0.0, clipmap_ring_levels);
	float cell = clipmap_cell * exp2(k);
	float morph = k < clipmap_ring_levels - 0.5
		? smoothstep(0.7, 1.0, cheb / (clipmap_half_extent * exp2(k))) : 0.0;
	vec2 grid = p / cell;
	VERTEX.xz = mesh_center + mix(p, (grid - mod(grid, 2.0)) * cell, morph);
	vec4 view_position = VIEW_MATRIX * vec4(VERTEX, 1.0);
	float view_distance = max(-view_position.z, 0.1);
	float pixel_world_size = 2.0 * view_distance / max(
		VIEWPORT_SIZE.y * abs(PROJECTION_MATRIX[1][1]), 1.0);

	world_uv = VERTEX.xz;
	// Each cascade fades with distance in proportion to its tile length: storm
	// swell (cascade 0, ~1 km tile) must stay visible for kilometres or the far
	// sea collapses into a flat mirror that merges with the sky. P0-C (cause
	// C6): the skirt shares the last ring's 32 m lattice, which carries
	// lambda >= 64 m — the swell octave is representable all the way out, so
	// the silhouette cascade keeps a fade floor instead of dying at 2.1 km.
	// The floor applies to every vertex including the skirt, so the join stays
	// crack-free by construction; aerial_density dissolves the far termination.
	float dist = length(VERTEX);
	vec3 displacement = vec3(0.0);
	geometry_weights = vec3(0.0);
	for (int i = 0; i < num_cascades; i++) {
		if (geometry_cascade >= 0 && i != geometry_cascade) {
			continue;
		}
		vec4 scales = map_scales[i];
		float tile = 1.0 / max(scales.x, 1e-6);
		float fade = min(exp(-(dist - max(tile * 0.7, 60.0)) * 2.5 / max(tile, 80.0)), 1.0);
		float wavelength = cascade_wavelength(i);
		float geometry_footprint = cell;
		float geometry_filter = 1.0 - smoothstep(wavelength * 0.18,
			wavelength * 0.48, geometry_footprint);
		float contribution = fade * geometry_filter;
		// Below ~0.5% the cascade moves vertices by millimetres: skip the
		// texture fetch entirely (outer clipmap rings, dead cascades).
		if (contribution < 0.005) {
			continue;
		}
		geometry_weights[i] = contribution;
		displacement += textureLod(displacements, vec3(world_uv * scales.xy, float(i)), 0.0).xyz
			* scales.z * contribution;
	}
	VERTEX += displacement;
	wave_height = displacement.y;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a * a;
	float a3 = a2 * a;
	float w0 = -a3 + a2 * 3.0 - a * 3.0 + 1.0;
	float w1 = a3 * 3.0 - a2 * 6.0 + 4.0;
	float w2 = -a3 * 3.0 + a2 * 3.0 + a * 3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Bicubic B-spline filtering via 4 bilinear taps. */
// Source: GPU Gems 2, ch. 20 - Fast Third-Order Texture Filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy * dims + 0.5;

	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy) * dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y);
}

vec4 texture_pixel_filtered(in sampler2DArray sampler, in vec3 uvw,
		in vec2 uv_dx, in vec2 uv_dy) {
	vec2 x = uv_dx * 0.35;
	vec2 y = uv_dy * 0.35;
	return (texture(sampler, vec3(uvw.xy + x + y, uvw.z))
		+ texture(sampler, vec3(uvw.xy + x - y, uvw.z))
		+ texture(sampler, vec3(uvw.xy - x + y, uvw.z))
		+ texture(sampler, vec3(uvw.xy - x - y, uvw.z))) * 0.25;
}

vec2 sample_foam_near_layer(int layer, vec2 world_pos, float domain, vec2 dx, vec2 dy) {
	float texel = domain / float(textureSize(foam_near_a, 0).x);
	vec2 center = floor(foam_near_center / texel) * texel;
	vec2 uv = (world_pos - center) / domain + 0.5;
	vec2 inside = step(vec2(0.0), uv) * step(uv, vec2(1.0));
	vec2 coverage = foam_near_index > 0.5
		? textureGrad(foam_near_b, vec3(uv, float(layer)), dx / domain, dy / domain).rg
		: textureGrad(foam_near_a, vec3(uv, float(layer)), dx / domain, dy / domain).rg;
	return coverage * inside.x * inside.y;
}

vec2 sample_foam_near(vec2 world_pos, vec2 dx, vec2 dy) {
	float distance_to_camera = length(world_pos - foam_near_center);
	for (int layer = 0; layer < 2; layer++) {
		float radius = foam_domains[layer] * 0.5;
		if (distance_to_camera < radius) {
			vec2 current = sample_foam_near_layer(layer, world_pos,
				foam_domains[layer], dx, dy);
			vec2 next = sample_foam_near_layer(layer + 1, world_pos,
				foam_domains[layer + 1], dx, dy);
			float transition = smoothstep(radius * 0.75, radius,
				distance_to_camera);
			return mix(current, next, transition);
		}
	}
	float outer_radius = foam_domains.z * 0.5;
	if (distance_to_camera < outer_radius) {
		vec2 outer = sample_foam_near_layer(2, world_pos, foam_domains.z, dx, dy);
		return outer * (1.0 - smoothstep(outer_radius * 0.75,
			outer_radius, distance_to_camera));
	}
	return vec2(0.0);
}

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	vec2 gradient = vec2(0.0);
	vec2 unresolved_gradient = vec2(0.0);
	vec3 deformation = vec3(0.0);
	vec2 height_gradient = vec2(0.0);
	float unresolved_slope_variance = 0.0;
	float peak_mask = 0.0;
	float breaking_mask = 0.0;
	float foam_history = 0.0;
	float foam_fresh = 0.0;
	float sss_crest_mask = 0.0;
	vec2 world_dx = dFdx(world_uv);
	vec2 world_dy = dFdy(world_uv);
	float pixel_footprint = max(length(world_dx), length(world_dy));
	for (int i = 0; i < num_cascades; i++) {
		if (geometry_cascade >= 0 && i != geometry_cascade) {
			continue;
		}
		vec4 scales = map_scales[i];
		vec3 coords = vec3(world_uv * scales.xy, float(i));
		float tile = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = exp(-dist * 0.32 / tile);
		float distance_fade = min(exp(-(length(world_uv - CAMERA_POSITION_WORLD.xz)
			- max(tile * 0.7, 60.0)) * 2.5 / max(tile, 80.0)), 1.0);
		if (fft_surface) {
			vec4 differential = texture(derivatives, coords);
			float geometry_fade = geometry_weights[i];
			deformation += differential.xyz * scales.z * geometry_fade;
			height_gradient += vec2(differential.w, texture(displacements, coords).a)
			* scales.z * geometry_fade;
		}
		float wavelength = cascade_wavelength(i);
		float detail_filter = 1.0 - smoothstep(wavelength * 0.22,
			wavelength * 0.55, pixel_footprint);
		float normal_weight = distance_fade * detail_filter;
		float resolved_weight = max(normal_weight, geometry_weights[i]);
		unresolved_slope_variance += cascade_slope_variance[i]
			* max(1.0 - resolved_weight * resolved_weight, 0.0);
		// Cheap pass first: the wave physics above stays continuous to the
		// horizon, but once the cascade's shading contribution is filtered
		// away the expensive bicubic + minification + foam taps are skipped.
		if (detail_filter < 0.004) {
			continue;
		}
		float texel_size = tile / map_size;
		float minification = smoothstep(texel_size, texel_size * 4.0, pixel_footprint);
		vec4 magnified = texture_bicubic(normals, coords);
		vec4 minified = texture_pixel_filtered(normals, coords,
			world_dx * scales.xy, world_dy * scales.xy);
		vec4 normal_sample = mix(magnified, minified, minification);
		if (fft_surface) {
			unresolved_gradient += normal_sample.xy * scales.w * normal_strength
				* max(normal_weight - geometry_weights[i], 0.0);
		}
		// P1-B.3 (cause C2): stop strangling the short cascades in the shader —
		// 0.42 -> 0.55 mid, 0.16 -> 0.32 ripple; detail_filter + Toksvig keep
		// the minification aliased-free.
		// P0-C.2: per-cascade floors keep the crest modulation alive in far
		// shading instead of collapsing into a flat mirror (lowered with the
		// distance de-sharpening: the far sea is allowed to calm down).
		float far_normal_floor = i == 0 ? 0.06 : (i == 1 ? 0.045 : 0.02);
		float far_crest_floor = i == 0 ? 0.07 : (i == 1 ? 0.05 : 0.05);
		gradient += normal_sample.xy * scales.w * normal_strength
			* max(cascade_fade, far_normal_floor) * detail_filter;
		peak_mask = max(peak_mask, normal_sample.z * max(cascade_fade, far_crest_floor)
			* detail_filter);
		// P3-A: weighted crest sum for the SSS path instead of one cascade.
		sss_crest_mask += normal_sample.z * max(cascade_fade, far_crest_floor)
			* detail_filter * (i == 0 ? 0.65 : (i == 1 ? 0.35 : 0.0));
		breaking_mask = max(breaking_mask,
			normal_sample.a * detail_filter);
	}
	if (fft_surface) {
		float a = 1.0 + deformation.x;
		float b = 1.0 + deformation.y;
		float c = deformation.z;
		float jacobian = a * b - c * c;
		float safe_jacobian = (jacobian < 0.0 ? -1.0 : 1.0) * max(abs(jacobian), 0.08);
		gradient = clamp(vec2(b * height_gradient.x - c * height_gradient.y,
			a * height_gradient.y - c * height_gradient.x) / safe_jacobian,
			vec2(-4.0), vec2(4.0)) * normal_strength;
		gradient += unresolved_gradient;
	}
	// Distance de-sharpening (perf/aliasing trade): the base 250 m to 1.5 km
	// range is scaled by the quality profile or the detail-distance slider.
	float detail_distance_scale = max(detail_distance_m / 1500.0, 0.25);
	float far_sharpness = mix(1.0, 0.35,
		smoothstep(250.0 * detail_distance_scale,
			1500.0 * detail_distance_scale, dist));
	gradient *= far_sharpness;
	peak_mask *= far_sharpness;
	sss_crest_mask *= far_sharpness;
	if (foam_near_enabled && foam_feedback_enabled) {
		vec2 near_coverage = sample_foam_near(world_uv, world_dx, world_dy);
		foam_history = near_coverage.r;
		foam_fresh = near_coverage.g;
	}
	crest_factor = clamp(peak_mask, 0.0, 1.0);
	// P3-A + review: overcast storms get no through-crest transmission — the
	// mood dims the SSS path so crest flanks stop glowing pale cyan.
	sss_crest_factor = clamp(sss_crest_mask, 0.0, 1.0) * mix(1.0, 0.5, storm_mood);

	vec2 wind = normalize(wind_direction);
	vec2 across = vec2(-wind.y, wind.x);
	vec2 wind_uv = vec2(dot(world_uv, wind), dot(world_uv, across));
	vec2 macro_gradient = gradient;
	vec2 micro_a_uv = wind_uv * micro_normal_scales.x
		+ vec2(TIME * 0.006, -TIME * 0.002);
	vec2 micro_a_dx = dFdx(wind_uv) * micro_normal_scales.x;
	vec2 micro_a_dy = dFdy(wind_uv) * micro_normal_scales.x;
	vec2 micro_a_filter_dx = micro_a_dx * 0.55;
	vec2 micro_a_filter_dy = micro_a_dy * 0.55;
	vec3 micro_a = (
		texture(micro_normal, micro_a_uv + micro_a_filter_dx + micro_a_filter_dy).rgb
		+ texture(micro_normal, micro_a_uv + micro_a_filter_dx - micro_a_filter_dy).rgb
		+ texture(micro_normal, micro_a_uv - micro_a_filter_dx + micro_a_filter_dy).rgb
		+ texture(micro_normal, micro_a_uv - micro_a_filter_dx - micro_a_filter_dy).rgb) * 0.5 - 1.0;
	vec2 crossed_uv = vec2(dot(world_uv, normalize(wind + across * 0.65)),
		dot(world_uv, normalize(across - wind * 0.65)));
	vec2 micro_b_uv = crossed_uv * micro_normal_scales.y
		+ vec2(-TIME * 0.009, TIME * 0.004);
	vec2 micro_b_dx = dFdx(crossed_uv) * micro_normal_scales.y;
	vec2 micro_b_dy = dFdy(crossed_uv) * micro_normal_scales.y;
	vec2 micro_b_filter_dx = micro_b_dx * 0.55;
	vec2 micro_b_filter_dy = micro_b_dy * 0.55;
	vec3 micro_b = (
		texture(micro_normal, micro_b_uv + micro_b_filter_dx + micro_b_filter_dy).rgb
		+ texture(micro_normal, micro_b_uv + micro_b_filter_dx - micro_b_filter_dy).rgb
		+ texture(micro_normal, micro_b_uv - micro_b_filter_dx + micro_b_filter_dy).rgb
		+ texture(micro_normal, micro_b_uv - micro_b_filter_dx - micro_b_filter_dy).rgb) * 0.5 - 1.0;
	float micro_distance_fade = 1.0 - smoothstep(
		micro_normal_fade_start * detail_distance_scale,
		micro_normal_fade_end * detail_distance_scale, dist);
	vec2 micro_size = vec2(textureSize(micro_normal, 0));
	float micro_texel_footprint = max(
		max(length(micro_a_dx), length(micro_a_dy)),
		max(length(micro_b_dx), length(micro_b_dy))) * max(micro_size.x, micro_size.y);
	float micro_pixel_fade = 1.0 - smoothstep(6.0, 18.0, micro_texel_footprint);
	vec2 micro_slope = (micro_a.xy + micro_b.xy * 0.62) * micro_normal_strength
		* micro_distance_fade * micro_pixel_fade;
	gradient += wind * micro_slope.x + across * micro_slope.y;
	float near_persistent_foam = clamp(foam_history * foam_strength, 0.0, 1.0);
	float near_fresh_foam = clamp(foam_fresh * foam_strength, 0.0, 1.0);
	float persistent_foam = near_persistent_foam;
	float fresh_foam = near_fresh_foam;
	vec2 breakup_uv = world_uv * 0.08 - wind * TIME * 0.003;
	// Same mip bias: shore/interaction breakup must stay soft clouds, not grain.
	float breakup = texture(foam_detail, breakup_uv, 2.0).g;
	float interaction_foam_factor = 0.0;
	if (foam_feedback_enabled) {
		vec2 interaction_uv = (world_uv - interaction_center) / interaction_size + 0.5;
		float inside = step(0.0, interaction_uv.x) * step(0.0, interaction_uv.y)
			* step(interaction_uv.x, 1.0) * step(interaction_uv.y, 1.0);
		if (inside > 0.0) {
			float interaction = texture(interaction_foam, interaction_uv).r;
			if (interaction > 0.0) {
				interaction_foam_factor = interaction * mix(0.65, 1.0, breakup);
			}
		}
	}
	float fresh_aa = max(fwidth(fresh_foam), 0.0005);
	float persistent_aa = max(fwidth(persistent_foam), 0.0005);
	float fresh_visible = smoothstep(0.022 - fresh_aa, 0.160 + fresh_aa, fresh_foam);
	float persistent_visible = smoothstep(0.018 - persistent_aa,
		0.110 + persistent_aa, persistent_foam) * 0.35;
	foam_factor = 1.0 - (1.0 - fresh_visible) * (1.0 - persistent_visible);
	foam_factor = max(foam_factor, interaction_foam_factor);
	gradient = mix(gradient, macro_gradient, clamp(foam_factor * 0.8, 0.0, 0.8));
	// P2: the glitter gets its OWN corridor (wider than the micro-relief one):
	// decoupling specularity from detail keeps the sun path bright without
	// dragging micro normals back behind a corridor gate.
	glitter_factor = mix(0.28, 0.92, smoothstep(0.08, 0.84, peak_mask));

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 roughness_normal = world_normal;
	vec3 normal_dx = dFdx(roughness_normal);
	vec3 normal_dy = dFdy(roughness_normal);
	float normal_variance = min(0.5 * (dot(normal_dx, normal_dx)
		+ dot(normal_dy, normal_dy)), 1.0);
	filtered_roughness = clamp(sqrt(roughness_base * roughness_base
		+ min(normal_variance + unresolved_slope_variance, 1.0) * 0.18),
		roughness_base, 0.65);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	float depth_lin = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
	float scene_depth = depth_lin + VERTEX.z;

	// Branch on which side of the interface the CAMERA is, never on the triangle
	// winding. Seen from near water level the far sea is edge-on, so the lee
	// slope of every wave (and every displaced crack filler) is back-facing
	// while still being the top of the water: FRONT_FACING would send those to
	// the underside path, whose down-pointing normal kills the diffuse and the
	// fresnel -> long black bands and black sawtooth at the horizon.
	if (!camera_underwater) {
		fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0),
			5.0 * exp(-2.69 * filtered_roughness))
			/ (1.0 + 22.7 * pow(filtered_roughness, 1.5)), 1.0, REFLECTANCE);
		vec3 deep_water = water_color.rgb;
		vec3 shallow_water = color_shallow.rgb;
		vec3 base_color = water_color.rgb;
		if (scene_depth < 12.0) {
			vec2 ref_uv = SCREEN_UV + NORMAL.xy * refraction_strength / max(dist * 0.2, 1.0);
			ref_uv = clamp(ref_uv, vec2(0.001), vec2(0.999));
			float r_raw = texture(depth_texture, ref_uv).r;
			float r_lin = PROJECTION_MATRIX[3][2] / (r_raw + PROJECTION_MATRIX[2][2]);
			// Refracted sample in front of the surface: fall back to
			// unrefracted (this is the anti-ghosting guard).
			if (r_lin + VERTEX.z > 0.0) {
				ref_uv = SCREEN_UV;
				r_lin = depth_lin;
			}
			float water_depth = r_lin + VERTEX.z;
			float depth_blend = clamp(1.0 - exp(-water_depth * beers_law), 0.0, 1.0);
			vec3 screen_color = textureLod(screen_texture, ref_uv, pow(depth_blend, 2.5) * 2.5).rgb;
			vec3 dye = mix(shallow_water, water_color.rgb, pow(depth_blend, 2.5));
			float refraction_weight = 1.0 - depth_blend;
			base_color = mix(base_color, screen_color * dye, refraction_weight);
		}

		float shore = 1.0 - smoothstep(0.0, 1.3, scene_depth);
		float shore_foam = shore * shore * smoothstep(0.18, 0.76, breakup + shore * 0.35)
			* exp(-dist * 0.02);
		foam_factor = max(foam_factor, min(shore_foam, 0.6));

		vec3 reflected_view = normalize(reflect(-VIEW, NORMAL));
		vec3 reflected_world = normalize((INV_VIEW_MATRIX * vec4(reflected_view, 0.0)).xyz);
		float sky_height = clamp(reflected_world.y * 1.8, 0.0, 1.0);
		vec3 reflected_horizon = mix(sky_horizon, sky_zenith, 0.82);
		vec3 reflected_sky = mix(reflected_horizon, sky_zenith, pow(sky_height, 0.45));
		if (cloud_reflection_enabled && reflected_view.z < -0.02) {
			vec4 cloud_clip = PROJECTION_MATRIX * vec4(reflected_view, 0.0);
			vec2 cloud_uv = cloud_clip.xy / max(cloud_clip.w, 1e-4) * 0.5 + 0.5;
			float cloud_valid = step(0.0, cloud_uv.x) * step(0.0, cloud_uv.y)
				* step(cloud_uv.x, 1.0) * step(cloud_uv.y, 1.0);
			// P2: explicit LOD + alpha floor kill the blocky-mip artefacts
			// (swell_day crenellated blocks top-left).
			vec4 cloud = textureLod(cloud_reflection,
				clamp(cloud_uv, vec2(0.001), vec2(0.999)), 2.0);
			float cloud_mix = smoothstep(0.04, 0.22, cloud.a) * cloud_valid;
			reflected_sky = mix(reflected_sky, cloud.rgb / max(cloud.a, 0.25), cloud_mix);
		}
		// P1-D.1 (cause C7): tint the reflection toward the deep water body —
		// raw sky in the troughs reads as an empty mirror, not a water column.
		vec3 reflection_tinted = mix(reflected_sky, deep_water * 1.6, 0.25);
		vec3 reflection_emission = reflection_tinted * fresnel
			* sky_reflection_strength * (1.0 - foam_factor * 0.72);

		float fresh_ratio = fresh_visible / max(persistent_visible + fresh_visible, 1e-3);
		// Foam is rougher than open water and fresh foam roughest of all; the
		// strong mix drowns the specular so foam never reads as a shiny plate.
		float foam_roughness = mix(0.82, 0.96, fresh_ratio);
		ROUGHNESS = mix(filtered_roughness, foam_roughness,
			clamp(foam_factor * 1.1, 0.0, 1.0));
		vec3 foam_tint = foam_color.rgb * mix(0.96, 1.04, fresh_ratio);
		ALBEDO = mix(base_color, foam_tint, foam_factor);
		// P0-C.3: atmospheric perspective converges the far sea CONTINUOUSLY
		// toward the sky, never below it — the old horizon_mix band pulled the
		// distance toward color_shallow*0.8, rendering darker than both the
		// water and the sky (the "black trough" at the horizon).
		float aerial = 1.0 - exp(-dist * aerial_density);
		vec3 horizon_color = mix(sky_horizon, sky_zenith, 0.15);
		ALBEDO = mix(ALBEDO, horizon_color, aerial);
		EMISSION = reflection_emission
			+ foam_tint * foam_factor * mix(0.03, 0.09, storm_mood);
		// P0-C.3 (completion): the haze replaces the OUTGOING radiance, not just
		// ALBEDO — otherwise the far field keeps mirroring the dark cloud base
		// at full strength and reads as a black band at the horizon seam.
		EMISSION *= 1.0 - aerial;
		if (debug_view == 1) {
			float debug_wavelength = geometry_cascade >= 0
				? cascade_wavelength(geometry_cascade) : cascade_wavelengths.x;
			float height_range = max(debug_wavelength * 0.04, 0.35);
			float height_debug = clamp(0.5 + wave_height / (height_range * 2.0),
				0.0, 1.0);
			ALBEDO = mix(vec3(0.18), vec3(0.86), height_debug);
			EMISSION = ALBEDO * 0.45;
			ROUGHNESS = 0.8;
			foam_factor = 0.0;
		} else if (debug_view == 2) {
			ALBEDO = world_normal * 0.5 + 0.5;
			EMISSION = ALBEDO * 0.4;
			ROUGHNESS = 1.0;
		} else if (debug_view == 3) {
			ALBEDO = vec3(crest_factor);
			EMISSION = ALBEDO;
			ROUGHNESS = 1.0;
		} else if (debug_view == 4) {
			ALBEDO = vec3(foam_factor);
			EMISSION = ALBEDO;
			ROUGHNESS = 1.0;
		} else if (debug_view == 5) {
			ALBEDO = vec3(smoothstep(0.0015, 0.018, foam_fresh));
			EMISSION = ALBEDO;
			ROUGHNESS = 1.0;
		} else if (debug_view == 6) {
			ALBEDO = vec3(smoothstep(0.003, 0.055, foam_history));
			EMISSION = ALBEDO;
			ROUGHNESS = 1.0;
		} else if (debug_view == 7) {
			ALBEDO = vec3(breaking_mask);
			EMISSION = ALBEDO;
			ROUGHNESS = 1.0;
		}
	} else {
		// Viewer submerged: every fragment is the underside of the interface —
		// refracted view of the air above, grazing angles falling into total
		// internal reflection toward the water body color.
		NORMAL = -NORMAL;
		float ndv = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
		vec2 ref_uv = SCREEN_UV + NORMAL.xy * refraction_strength * 4.0;
		ref_uv = clamp(ref_uv, vec2(0.001), vec2(0.999));
		vec3 above = textureLod(screen_texture, ref_uv, 0.0).rgb;
		float tir = 1.0 - smoothstep(0.35, 0.65, ndv);
		foam_factor *= 0.8; // folded crests are breaking water: show the churn
		fresnel = 0.0;      // no sun glints through the interface
		ALBEDO = mix(mix(above * color_shallow.rgb * 1.5, color_shallow.rgb * 0.6, tir),
			foam_color.rgb * 0.85, foam_factor);
			ROUGHNESS = 0.2;
			SPECULAR = 0.1;
			EMISSION = vec3(0.0);
		}
	if (debug_view == 8) {
		ALBEDO = vec3(0.0);
		EMISSION = vec3(foam_factor, clamp(dist / 2000.0, 0.0, 1.0), 1.0);
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	}
}

float smith_masking_shadowing(float cos_theta, float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(float cos_theta, float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	if (debug_view != 8) {
	vec3 area_light = LIGHT;
	vec3 halfway = normalize(area_light + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	float broad_roughness = max(ROUGHNESS, sun_path_width * 6.0);
	float light_mask = smith_masking_shadowing(dot_nl, broad_roughness);
	float view_mask = smith_masking_shadowing(dot_nv, broad_roughness);
	float d_ggx = ggx_distribution(max(dot(NORMAL, halfway), 0.0), broad_roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	vec3 narrow_halfway = normalize(LIGHT + VIEW);
	float narrow_roughness = max(ROUGHNESS * 0.46, 0.026);
	float narrow_distribution = ggx_distribution(max(dot(NORMAL, narrow_halfway), 0.0),
		narrow_roughness);
	// P2: stronger narrow lobe for glints, reinforced at low sun (hundreds of
	// white-gold fragments instead of one molten ribbon); the 4.0 product cap
	// keeps fireflies out.
	float narrow_weight = min(glitter_factor
		* mix(1.0, 2.2, 1.0 - smoothstep(0.05, 0.35, sun_direction.y)), 4.0);
	float path = d_ggx * 0.24 + narrow_distribution * glitter_factor * 0.045;
	SPECULAR_LIGHT += fresnel * path * geometric_attenuation / (4.0 * dot_nv + 0.1)
		* ATTENUATION * LIGHT_COLOR / PI * sun_glitter_strength * (1.0 - foam_factor);

	float crest_transmission = smoothstep(0.42, 0.82, sss_crest_factor);
	float backlight = pow(max(dot(LIGHT, -VIEW), 0.0), 5.0);
	float thin_face = pow(clamp(0.5 - 0.5 * dot(LIGHT, NORMAL), 0.0, 1.0), 2.0);
	float sss_height = sss_strength * crest_transmission * backlight * thin_face * 0.18;
	vec3 sss_tint = mix(vec3(1.0), color_shallow.rgb, 0.45);
	float wrapped = max(dot_nl * 0.68 + 0.32, 0.0);
	float lambertian = 0.38 * wrapped;
	vec3 transmission = sss_height * sss_tint / (1.0 + light_mask)
		+ vec3(lambertian);
	DIFFUSE_LIGHT += mix(transmission,
		foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
