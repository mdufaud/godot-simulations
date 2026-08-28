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
uniform int style_mode = 0;
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
uniform sampler2DArray foam_history_a : filter_linear, repeat_enable;
uniform sampler2DArray foam_history_b : filter_linear, repeat_enable;
uniform vec4 foam_history_indices = vec4(0.0);
uniform sampler2D foam_pattern : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D foam_breakup : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D micro_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec2 micro_normal_scales = vec2(0.085, 0.23);
uniform float micro_normal_strength = 0.42;
uniform float micro_normal_fade_start = 70.0;
uniform float micro_normal_fade_end = 360.0;
uniform sampler2D cloud_reflection : filter_linear, repeat_disable, hint_default_black;
uniform bool cloud_reflection_enabled = true;
uniform vec3 sky_zenith : source_color = vec3(0.055, 0.18, 0.43);
uniform vec3 sky_horizon : source_color = vec3(0.95, 0.43, 0.18);
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
varying float glitter_factor;
varying float filtered_roughness;

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
	// sea collapses into a flat mirror that merges with the sky. Fades complete
	// before the clipmap edge (~2.1 km) so the flat skirt joins seamlessly.
	float dist = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	vec3 displacement = vec3(0.0);
	for (int i = 0; i < num_cascades; i++) {
		if (geometry_cascade >= 0 && i != geometry_cascade) {
			continue;
		}
		vec4 scales = map_scales[i];
		float tile = 1.0 / max(scales.x, 1e-6);
		float fade = min(exp(-(dist - max(tile * 0.7, 60.0)) * 2.5 / max(tile, 80.0)), 1.0);
		float wavelength = cascade_wavelength(i);
		float geometry_footprint = style_mode == 1
			? max(cell * 1.25, pixel_world_size * 1.75) : cell;
		float geometry_filter = 1.0 - smoothstep(wavelength * 0.18,
			wavelength * 0.48, geometry_footprint);
		displacement += textureLod(displacements, vec3(world_uv * scales.xy, float(i)), 0.0).xyz
			* scales.z * fade * geometry_filter;
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

float foam_history_index(int cascade) {
	return cascade == 0 ? foam_history_indices.x
		: (cascade == 1 ? foam_history_indices.y : foam_history_indices.z);
}

vec4 sample_foam_history(vec3 coords) {
	int cascade = int(coords.z + 0.5);
	return foam_history_index(cascade) > 0.5
		? texture(foam_history_b, coords)
		: texture(foam_history_a, coords);
}

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX);
	vec2 gradient = vec2(0.0);
	float peak_mask = 0.0;
	float breaking_mask = 0.0;
	float foam_history = 0.0;
	float foam_fresh = 0.0;
	float foam_breaking = 0.0;
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
		float texel_size = tile / map_size;
		float minification = smoothstep(texel_size, texel_size * 4.0, pixel_footprint);
		vec4 magnified = texture_bicubic(normals, coords);
		vec4 minified = texture_pixel_filtered(normals, coords,
			world_dx * scales.xy, world_dy * scales.xy);
		vec4 normal_sample = mix(magnified, minified, minification);
		float wavelength = cascade_wavelength(i);
		float detail_filter = 1.0 - smoothstep(wavelength * 0.22,
			wavelength * 0.55, pixel_footprint);
		float style_normal_weight = style_mode == 1
			? (i == 0 ? 1.0 : (i == 1 ? 0.42 : 0.16)) : 1.0;
		gradient += normal_sample.xy * scales.w * normal_strength
			* max(cascade_fade, 0.025) * detail_filter * style_normal_weight;
		peak_mask = max(peak_mask, normal_sample.z * max(cascade_fade, 0.08)
			* detail_filter);
		if (style_mode == 1) {
			if (i == 1) {
				float foam_visibility = cascade_fade * detail_filter;
				foam_breaking = normal_sample.a * foam_visibility;
				if (foam_feedback_enabled && foam_visibility > 0.0) {
					vec4 foam_sample = sample_foam_history(coords);
					foam_history = foam_sample.r * foam_visibility;
					foam_fresh = foam_sample.g * foam_visibility;
				}
			}
		} else {
			if (foam_feedback_enabled) {
				vec4 foam_sample = sample_foam_history(coords);
				foam_history = max(foam_history, foam_sample.r * detail_filter);
				foam_fresh = max(foam_fresh, foam_sample.g * detail_filter);
			}
		}
		breaking_mask = max(breaking_mask, normal_sample.a * detail_filter);
	}
	crest_factor = clamp(peak_mask, 0.0, 1.0);

	vec2 wind = normalize(wind_direction);
	vec2 across = vec2(-wind.y, wind.x);
	vec2 wind_uv = vec2(dot(world_uv, wind), dot(world_uv, across));
	vec2 macro_gradient = gradient;
	vec3 macro_world_normal = normalize(vec3(-macro_gradient.x, 1.0,
		-macro_gradient.y));
	vec3 macro_normal = normalize((VIEW_MATRIX * vec4(macro_world_normal, 0.0)).xyz);
	vec3 sun_view = normalize((VIEW_MATRIX * vec4(sun_direction, 0.0)).xyz);
	vec3 macro_reflection = normalize(reflect(-VIEW, macro_normal));
	float sun_alignment = max(dot(macro_reflection, sun_view), 0.0);
	float corridor_width = max(sun_path_width * 10.0, 0.12);
	float micro_corridor = style_mode == 1
		? sqrt(smoothstep(cos(corridor_width), cos(corridor_width * 0.35), sun_alignment))
		: 1.0;
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
	float micro_distance_fade = 1.0 - smoothstep(micro_normal_fade_start,
		micro_normal_fade_end, dist);
	vec2 micro_size = vec2(textureSize(micro_normal, 0));
	float micro_texel_footprint = max(
		max(length(micro_a_dx), length(micro_a_dy)),
		max(length(micro_b_dx), length(micro_b_dy))) * max(micro_size.x, micro_size.y);
	float micro_pixel_fade = 1.0 - smoothstep(6.0, 18.0, micro_texel_footprint);
	float style_micro_strength = style_mode == 1 ? 0.35 : 1.0;
	vec2 micro_slope = (micro_a.xy + micro_b.xy * 0.62) * micro_normal_strength
		* micro_distance_fade * micro_pixel_fade * style_micro_strength * micro_corridor;
	gradient += wind * micro_slope.x + across * micro_slope.y;
	float persistent_source = clamp(foam_history * foam_strength * 0.92, 0.0, 1.0);
	float fresh_signal = style_mode == 1 && foam_feedback_enabled
		? max(foam_fresh, foam_breaking * 0.16) : foam_fresh;
	float fresh_source = clamp(fresh_signal * foam_strength * 1.35, 0.0, 1.0);
	float persistent_foam = style_mode == 1
		? smoothstep(0.018, 0.16, persistent_source)
		: smoothstep(0.08, 0.58, persistent_source);
	float fresh_foam = style_mode == 1
		? smoothstep(0.006, 0.055, fresh_source)
		: smoothstep(0.03, 0.38, fresh_source);
	float ridge_boost = mix(0.82, 1.12, smoothstep(0.18, 0.72, peak_mask));
	persistent_foam *= ridge_boost;
	fresh_foam *= ridge_boost;
	vec2 breakup_uv = world_uv * 0.19 - wind * TIME * 0.006;
	float breakup = 1.0;
	float ocean_foam = 0.0;
	if (style_mode == 1) {
		if (foam_feedback_enabled && (persistent_foam > 0.0 || fresh_foam > 0.0)) {
			vec2 ribbon_uv = wind_uv * vec2(0.055, 0.16)
				- vec2(TIME * 0.002, TIME * 0.007);
			float ribbon_art = textureGrad(foam_pattern, ribbon_uv,
				dFdx(ribbon_uv), dFdy(ribbon_uv)).r;
			float ribbon_detail = smoothstep(0.18, 0.72, ribbon_art);
			float breakup_art = textureGrad(foam_breakup, breakup_uv,
				dFdx(breakup_uv), dFdy(breakup_uv)).r;
			float breakup_detail = smoothstep(0.24, 0.76, breakup_art);
			persistent_foam *= mix(0.34, 1.0, ribbon_detail * breakup_detail);
			fresh_foam *= mix(0.70, 1.0, mix(ribbon_detail, 1.0, breakup_detail));
			ocean_foam = 1.0 - (1.0 - persistent_foam * 0.92)
				* (1.0 - fresh_foam * 1.12);
		}
	} else {
		breakup = texture(foam_breakup, breakup_uv).r;
		float breakup_mask = smoothstep(0.34, 0.72, breakup);
		float physical_foam = max(persistent_foam * 0.96, fresh_foam * 1.28);
		ocean_foam = physical_foam * mix(0.86, 1.0, breakup_mask);
	}
	foam_factor = ocean_foam * exp(-dist * 0.0015);
	if (style_mode == 1 && foam_feedback_enabled) {
		vec2 interaction_uv = (world_uv - interaction_center) / interaction_size + 0.5;
		float inside = step(0.0, interaction_uv.x) * step(0.0, interaction_uv.y)
			* step(interaction_uv.x, 1.0) * step(interaction_uv.y, 1.0);
		if (inside > 0.0) {
			float interaction = texture(interaction_foam, interaction_uv).r;
			if (interaction > 0.0) {
				breakup = textureGrad(foam_breakup, breakup_uv,
					dFdx(breakup_uv), dFdy(breakup_uv)).r;
				foam_factor = max(foam_factor, interaction * mix(0.65, 1.0, breakup));
			}
		}
	}
	glitter_factor = style_mode == 1 ? micro_corridor
		: mix(0.28, 0.92, smoothstep(0.08, 0.84, peak_mask));

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 roughness_normal = world_normal;
	vec3 normal_dx = dFdx(roughness_normal);
	vec3 normal_dy = dFdy(roughness_normal);
	float normal_variance = min(0.5 * (dot(normal_dx, normal_dx)
		+ dot(normal_dy, normal_dy)), 1.0);
	filtered_roughness = clamp(sqrt(roughness_base * roughness_base
		+ normal_variance * 0.18), roughness_base, 0.65);
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
		vec3 sun_view = normalize((VIEW_MATRIX * vec4(sun_direction, 0.0)).xyz);
		float view_angle = 1.0 - max(dot(VIEW, NORMAL), 0.0);
		float backlight = pow(max(dot(VIEW, -sun_view), 0.0), 2.0);
		float sun_facing = max(dot(world_normal, -sun_direction), 0.0);
		float slope_amount = clamp(1.0 - world_normal.y, 0.0, 1.0);
		float flank_mask = smoothstep(0.04, 0.26, slope_amount);
		float crest_mask = smoothstep(0.22, 0.68, crest_factor);
		float height_scale = max(cascade_wavelengths.x * 0.03, 1.2);
		float height_normalized = clamp(wave_height / height_scale, -1.0, 1.0);
		float height_flank = smoothstep(-0.55, 0.18, height_normalized)
			* (1.0 - 0.35 * smoothstep(0.25, 0.8, height_normalized));
		float height_crest = smoothstep(0.18, 0.72, height_normalized);
		float flank_band = max(flank_mask, height_flank * 0.58);
		float crest_signal = max(crest_mask, height_crest);
		float sun_transmission = clamp(0.32 + sun_facing * 0.38
			+ backlight * 0.30, 0.0, 1.0);
		float transmission_mask = crest_signal
			* smoothstep(0.22, 0.66, sun_transmission)
			* (0.65 + 0.35 * smoothstep(0.16, 0.72, view_angle));
		float crest_light = clamp(0.20 + sun_facing * 0.45
			+ backlight * 0.25 + view_angle * 0.10, 0.0, 1.0);
		float crest_band = crest_signal * crest_light;
		float wrapped_transmission = style_mode == 1
			? pow(max(dot(VIEW, -sun_view), 0.0), 1.6)
				* (0.08 + slope_amount * 0.72)
			: pow(max(dot(VIEW, -sun_view), 0.0), 1.6)
				* (0.12 + slope_amount * 0.9);
		float crest_scatter = style_mode == 1
			? crest_signal * (0.32 + 0.25 * view_angle
				+ 0.48 * backlight + 0.18 * sun_facing)
			: crest_factor * (0.42 + 0.28 * view_angle + 0.55 * backlight);
		float weather_mix = style_mode == 1
			? smoothstep(0.25, 0.9, storm_mood) : 0.0;
		vec3 deep_water = style_mode == 1
			? mix(vec3(0.105, 0.27, 0.26), vec3(0.075, 0.19, 0.19),
				weather_mix * 0.35) : water_color.rgb;
		vec3 shallow_water = style_mode == 1
			? mix(vec3(0.24, 0.46, 0.38), vec3(0.19, 0.34, 0.30),
				weather_mix * 0.25) : color_shallow.rgb;
		float flank_strength = style_mode == 1 ? 0.50 : 0.36;
		float flank_mix = clamp(0.025 + flank_band * flank_strength,
			0.025, 0.60);
		vec3 base_color;
		if (style_mode == 1) {
			base_color = mix(deep_water, shallow_water * 0.84, flank_mix);
			float crest_mix = clamp(crest_band * 0.50
				+ transmission_mask * (0.16 + sun_facing * 0.52
				+ backlight * 0.22)
				+ wrapped_transmission * 0.08, 0.0, 0.48);
			base_color = mix(base_color, shallow_water * 1.05, crest_mix);
		} else {
			float slope_scatter = clamp(slope_amount * 0.72
				+ view_angle * 0.06, 0.0, 0.2);
			float face_scatter = clamp(0.045 + slope_scatter
				+ crest_scatter, 0.0, 1.0);
			base_color = mix(water_color.rgb, color_shallow.rgb * 1.18,
				face_scatter);
		}
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
			vec3 refraction_shallow = mix(shallow_water, deep_water,
				style_mode == 1 ? 0.18 : 0.0);
			vec3 dye = mix(refraction_shallow, water_color.rgb, pow(depth_blend, 2.5));
			float refraction_weight = (1.0 - depth_blend)
				* (style_mode == 1 ? 0.55 : 1.0);
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
			vec4 cloud = texture(cloud_reflection, clamp(cloud_uv, vec2(0.001), vec2(0.999)));
			float cloud_mix = smoothstep(0.04, 0.22, cloud.a) * cloud_valid
				* (style_mode == 1 ? 0.38 : 1.0);
			reflected_sky = mix(reflected_sky, cloud.rgb / max(cloud.a, 0.08), cloud_mix);
		}
		vec3 reflection_emission = reflected_sky * fresnel
			* sky_reflection_strength * (1.0 - foam_factor * 0.72);

		float fresh_ratio = fresh_foam / max(persistent_foam + fresh_foam, 1e-3);
		float foam_roughness = mix(0.76, 0.95, fresh_ratio);
		ROUGHNESS = mix(filtered_roughness, foam_roughness,
			clamp(foam_factor * 1.05, 0.0, 1.0));
		vec3 persistent_tint = foam_color.rgb * 0.68;
		vec3 fresh_tint = foam_color.rgb * 1.12;
		vec3 foam_tint = mix(persistent_tint, fresh_tint,
			clamp(fresh_ratio * 0.92, 0.0, 1.0));
		ALBEDO = mix(base_color, foam_tint, foam_factor);
		float horizon_mix = style_mode == 1
			? smoothstep(420.0, 1500.0, dist) * 0.28 : 0.0;
		ALBEDO = mix(ALBEDO,
			mix(color_shallow.rgb * 0.8, sky_horizon, 0.42), horizon_mix);
		vec3 stable_water = mix(deep_water, shallow_water * 0.82,
			clamp(flank_band * 0.62 + crest_band * 0.45
			+ transmission_mask * 0.72, 0.0, 1.0));
		float water_fill = style_mode == 1
			? mix(0.035, 0.14, weather_mix) : 0.0;
		EMISSION = reflection_emission
			+ stable_water * water_fill
			+ shallow_water * transmission_mask
			* (style_mode == 1 ? 0.045 : 0.0)
			+ color_shallow.rgb * crest_scatter
			* (style_mode == 1 ? 0.18 : 0.28) * (1.0 - foam_factor)
			+ color_shallow.rgb * wrapped_transmission * 0.18 * (1.0 - foam_factor)
			+ foam_tint * foam_factor * (style_mode == 1 ? 0.035 : 0.03);
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
		if (style_mode == 1) {
			float critical_cos = sqrt(1.0 - 1.0 / (1.333 * 1.333));
			float snell_window = smoothstep(critical_cos - 0.035, critical_cos + 0.035, ndv);
			above = mix(color_shallow.rgb * 0.18,
				above * vec3(0.58, 0.82, 1.0), snell_window);
			tir = 1.0 - snell_window;
		}
		foam_factor *= 0.8; // folded crests are breaking water: show the churn
		fresnel = 0.0;      // no sun glints through the interface
		ALBEDO = mix(mix(above * color_shallow.rgb * 1.5, color_shallow.rgb * 0.6, tir),
			foam_color.rgb * 0.85, foam_factor);
		ROUGHNESS = 0.2;
		SPECULAR = 0.1;
		EMISSION = vec3(0.0);
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
	vec3 area_light = LIGHT;
	if (style_mode == 1) {
		vec3 reflection_ray = reflect(-VIEW, NORMAL);
		vec3 center_to_ray = dot(LIGHT, reflection_ray) * reflection_ray - LIGHT;
		float center_distance = length(center_to_ray);
		float area_radius = sun_disk_radius + sun_path_width;
		area_light = normalize(LIGHT + center_to_ray
			* clamp(sin(area_radius) / max(center_distance, 1e-5), 0.0, 1.0));
	}
	vec3 halfway = normalize(area_light + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	float broad_roughness = max(filtered_roughness, sun_path_width * 6.0);
	float light_mask = smith_masking_shadowing(dot_nl, broad_roughness);
	float view_mask = smith_masking_shadowing(dot_nv, broad_roughness);
	float d_ggx = ggx_distribution(max(dot(NORMAL, halfway), 0.0), broad_roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	vec3 narrow_halfway = normalize(LIGHT + VIEW);
	float narrow_roughness = max(filtered_roughness * 0.46, 0.026);
	float narrow_distribution = ggx_distribution(max(dot(NORMAL, narrow_halfway), 0.0),
		narrow_roughness);
	float path = style_mode == 1
		? d_ggx * mix(0.06, 0.12, glitter_factor)
			+ narrow_distribution * glitter_factor * 0.035
		: d_ggx * 0.24 + narrow_distribution * glitter_factor * 0.045;
	SPECULAR_LIGHT += fresnel * path * geometric_attenuation / (4.0 * dot_nv + 0.1)
		* ATTENUATION * LIGHT_COLOR / PI * sun_glitter_strength;

	const vec3 sss_modifier = vec3(0.9, 1.15, 0.85);
	float sss_height = sss_strength * crest_factor * pow(max(dot(LIGHT, -VIEW), 0.0), 3.0)
		* pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0);
	float backscatter = style_mode == 1
		? sss_strength * pow(max(dot(VIEW, -LIGHT), 0.0), 1.6)
			* smoothstep(0.08, 0.55, 1.0 - NORMAL.y)
			* (0.25 + 0.75 * crest_factor) : 0.0;
	float wrapped = max(dot_nl * 0.68 + 0.32, 0.0);
	float lambertian = 0.38 * wrapped;
	vec3 transmission = sss_height * sss_modifier / (1.0 + light_mask)
		+ vec3(lambertian)
		+ vec3(0.10, 0.42, 0.25) * backscatter;
	DIFFUSE_LIGHT += mix(transmission,
		foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR / PI;
}
