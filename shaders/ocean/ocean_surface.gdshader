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
uniform float storm_mood = 0.15;
uniform float clipmap_cell = 0.25;
uniform float clipmap_half_extent = 8.0;
uniform float clipmap_ring_levels = 8.0;
uniform vec3 cascade_wavelengths = vec3(48.0, 7.5, 0.72);
uniform int debug_view = 0;
uniform int num_cascades = 3;
uniform vec4 map_scales[MAX_CASCADES]; // xy = uv scale (1/tile), z = displacement scale, w = normal scale
uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform sampler2DArray normals : filter_linear, repeat_enable;
uniform sampler2D foam_pattern : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D foam_breakup : filter_linear_mipmap, repeat_enable, hint_default_white;
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

	world_uv = VERTEX.xz;
	// Each cascade fades with distance in proportion to its tile length: storm
	// swell (cascade 0, ~1 km tile) must stay visible for kilometres or the far
	// sea collapses into a flat mirror that merges with the sky. Fades complete
	// before the clipmap edge (~2.1 km) so the flat skirt joins seamlessly.
	float dist = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	vec3 displacement = vec3(0.0);
	for (int i = 0; i < num_cascades; i++) {
		vec4 scales = map_scales[i];
		float tile = 1.0 / max(scales.x, 1e-6);
		float fade = min(exp(-(dist - max(tile * 0.7, 60.0)) * 2.5 / max(tile, 80.0)), 1.0);
		float wavelength = cascade_wavelength(i);
		float geometry_filter = 1.0 - smoothstep(wavelength * 0.22,
			wavelength * 0.48, cell);
		displacement += textureLod(displacements, vec3(world_uv * scales.xy, float(i)), 0.0).xyz
			* scales.z * fade * geometry_filter;
	}
	VERTEX += displacement;
	wave_height = displacement.y;
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
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

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX);
	vec2 gradient = vec2(0.0);
	float peak_mask = 0.0;
	float foam_history = 0.0;
	vec2 world_dx = dFdx(world_uv);
	vec2 world_dy = dFdy(world_uv);
	float pixel_footprint = max(length(world_dx), length(world_dy));
	for (int i = 0; i < num_cascades; i++) {
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
		gradient += normal_sample.xy * scales.w * normal_strength
			* max(cascade_fade, 0.025) * detail_filter;
		peak_mask = max(peak_mask, normal_sample.z * max(cascade_fade, 0.08)
			* detail_filter);
		foam_history += normal_sample.w * detail_filter;
	}
	crest_factor = clamp(peak_mask, 0.0, 1.0);

	vec2 wind = normalize(wind_direction);
	vec2 across = vec2(-wind.y, wind.x);
	vec2 foam_uv = vec2(dot(world_uv, across) * 0.018, dot(world_uv, wind) * 0.055);
	float filament = texture(foam_pattern, foam_uv + vec2(TIME * 0.006, -TIME * 0.011)).r;
	float breakup = texture(foam_breakup, world_uv * 0.19 - wind * TIME * 0.018).r;
	float foam_noise = value_noise(world_uv * 1.7 + vec2(TIME * 0.35)) * 0.6
		+ value_noise(world_uv * 6.3 - vec2(TIME * 0.5)) * 0.4;
	float foam_source = foam_history * 0.75 * foam_strength;
	float ocean_foam = smoothstep(0.15, 1.1,
		foam_source * mix(0.7, 1.3, foam_noise));
	foam_factor = ocean_foam * exp(-dist * 0.0015);
	if (style_mode == 1) {
		vec2 interaction_uv = (world_uv - interaction_center) / interaction_size + 0.5;
		float inside = step(0.0, interaction_uv.x) * step(0.0, interaction_uv.y)
			* step(interaction_uv.x, 1.0) * step(interaction_uv.y, 1.0);
		float interaction = texture(interaction_foam, interaction_uv).r * inside;
		foam_factor = max(foam_factor, interaction * mix(0.65, 1.0, breakup));
	}
	glitter_factor = mix(0.16, 1.4, smoothstep(0.28, 0.82, breakup))
		* mix(0.72, 1.18, filament);

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 normal_dx = dFdx(world_normal);
	vec3 normal_dy = dFdy(world_normal);
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
		float crest_scatter = crest_factor * (0.42 + 0.28 * view_angle + 0.55 * backlight);
		float slope_scatter = clamp((1.0 - world_normal.y) * 0.72 + view_angle * 0.06,
			0.0, 0.2);
		float face_scatter = clamp(0.045 + slope_scatter + crest_scatter, 0.0, 1.0);
		vec3 base_color = mix(water_color.rgb, color_shallow.rgb * 1.18, face_scatter);
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
			vec3 dye = mix(color_shallow.rgb, water_color.rgb, pow(depth_blend, 2.5));
			base_color = mix(screen_color * dye, base_color, depth_blend);
		}

		float shore = 1.0 - smoothstep(0.0, 1.3, scene_depth);
		float shore_foam = shore * shore * smoothstep(0.18, 0.76, breakup + shore * 0.35)
			* exp(-dist * 0.02);
		foam_factor = max(foam_factor, min(shore_foam, 0.6));

		ROUGHNESS = min((1.0 - fresnel) * foam_factor + filtered_roughness, 1.0);
		ALBEDO = mix(base_color, foam_color.rgb, foam_factor);
		EMISSION = color_shallow.rgb * crest_scatter * 0.08 * (1.0 - foam_factor);
		if (debug_view == 1) {
			ALBEDO = vec3(0.38);
			EMISSION = vec3(0.0);
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

	float light_mask = smith_masking_shadowing(dot_nl, filtered_roughness);
	float view_mask = smith_masking_shadowing(dot_nv, filtered_roughness);
	float d_ggx = ggx_distribution(max(dot(NORMAL, halfway), 0.0), filtered_roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * d_ggx * geometric_attenuation / (4.0 * dot_nv + 0.1)
		* ATTENUATION * LIGHT_COLOR / PI * glitter_factor * sun_glitter_strength;

	const vec3 sss_modifier = vec3(0.9, 1.15, 0.85);
	float sss_height = sss_strength * crest_factor * pow(max(dot(LIGHT, -VIEW), 0.0), 3.0)
		* pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0);
	float lambertian = 0.42 * dot_nl;
	DIFFUSE_LIGHT += mix(sss_height * sss_modifier / (1.0 + light_mask) + vec3(lambertian),
		foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR / PI;
}
