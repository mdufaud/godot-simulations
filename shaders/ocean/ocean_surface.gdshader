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
uniform int num_cascades = 3;
uniform vec4 map_scales[MAX_CASCADES]; // xy = uv scale (1/tile), z = displacement scale, w = normal scale
uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform sampler2DArray normals : filter_linear, repeat_enable;

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

void vertex() {
	// Geomorph (GPU Gems 2 ch. 2): the outer 30% of every clipmap level slides
	// its odd vertices onto the next-coarser lattice, so both sides of each 2:1
	// boundary sample the displacement at identical world positions and cracks
	// are zero by construction. Distance fades alone cannot do this: metre-tall
	// gaps opened wherever storm swell met coarse cells, rendering as dark
	// triangular fins. Constants mirror OceanClipmap (cell0 0.5, half-extent
	// 16*2^k, 8 levels); level 7 never morphs - the skirt shares its lattice.
	vec2 mesh_center = MODEL_MATRIX[3].xz;
	vec2 p = VERTEX.xz - mesh_center;
	float cheb = max(abs(p.x), abs(p.y));
	float k = clamp(ceil(log2(max(cheb, 1.0) / 16.0) - 0.001), 0.0, 7.0);
	float cell = 0.5 * exp2(k);
	float morph = k < 6.5 ? smoothstep(0.7, 1.0, cheb / (16.0 * exp2(k))) : 0.0;
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
		displacement += textureLod(displacements, vec3(world_uv * scales.xy, float(i)), 0.0).xyz
			* scales.z * fade;
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

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX);

	// gradient.xy = surface slope, gradient.z = accumulated Jacobian foam.
	// Slopes fade per cascade like the vertex displacement: the swell cascade
	// keeps texturing the sea (and the flat skirt) out to the horizon, the fine
	// cascades die early so their sub-pixel detail never shimmers.
	vec3 gradient = vec3(0.0);
	for (int i = 0; i < num_cascades; i++) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(world_uv * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // texels per meter
		float tile = 1.0 / max(scales.x, 1e-6);
		float n_fade = mix(0.015, normal_strength, exp(-dist * 0.4 / tile));
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords),
			min(1.0, ppm * 0.1)).xyw * vec3(scales.ww * n_fade, 1.0);
	}

	// Break the flat Jacobian foam patches with two octaves of animated value
	// noise so whitecaps read as churned texture instead of white blobs.
	float foam_noise = value_noise(world_uv * 1.7 + vec2(TIME * 0.35)) * 0.6
		+ value_noise(world_uv * 6.3 - vec2(TIME * 0.5)) * 0.4;
	float foam_amount_px = gradient.z * 0.75 * foam_strength;
	foam_factor = smoothstep(0.15, 1.1, foam_amount_px * mix(0.7, 1.3, foam_noise))
		* exp(-dist * 0.0015);

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
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
		// Roughness-compensated Schlick fresnel (Atlas).
		fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0 * exp(-2.69 * roughness_base))
			/ (1.0 + 22.7 * pow(roughness_base, 1.5)), 1.0, REFLECTANCE);

		// Guarded screen-space refraction + Beer absorption, only meaningful
		// where geometry sits close beneath the surface (rocks). Open ocean
		// stays opaque.
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
			vec3 dye = mix(color_shallow.rgb, water_color.rgb, pow(depth_blend, 2.5));
			base_color = mix(screen_color * dye, base_color, depth_blend);
		}

		// Contact foam where the water meets emerged geometry (rocks): a
		// narrow churned band, noise-broken so it reads as wash, not ice.
		float shore = 1.0 - smoothstep(0.0, 1.3, scene_depth);
		float shore_foam = shore * shore * smoothstep(0.25, 0.9, foam_noise + shore * 0.35)
			* exp(-dist * 0.02);
		foam_factor = max(foam_factor, min(shore_foam, 0.6));

		ROUGHNESS = (1.0 - fresnel) * foam_factor + roughness_base;
		ALBEDO = mix(base_color, foam_color.rgb, foam_factor);
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
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	float light_mask = smith_masking_shadowing(dot_nl, roughness_base);
	float view_mask = smith_masking_shadowing(dot_nv, roughness_base);
	float d_ggx = ggx_distribution(max(dot(NORMAL, halfway), 0.0), roughness_base);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * d_ggx * geometric_attenuation / (4.0 * dot_nv + 0.1)
		* ATTENUATION * LIGHT_COLOR / PI;

	// Subsurface scattering through wave flanks reads greener than the body.
	const vec3 sss_modifier = vec3(0.9, 1.15, 0.85);
	float sss_height = sss_strength * max(0.0, wave_height + 2.5)
		* pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	float sss_near = 0.5 * pow(dot_nv, 2.0);
	float lambertian = 0.5 * dot_nl;
	DIFFUSE_LIGHT += mix((sss_height + sss_near) * sss_modifier / (1.0 + light_mask) + vec3(lambertian),
		foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR / PI;
}
