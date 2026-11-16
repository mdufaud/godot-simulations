// ============================================================
// Fire volume raymarcher — shared body
// Inspired by Fire-X (Wrede et al., SIGGRAPH Asia 2025)
// Volume channels: R = normalized temperature, G = smoke/soot,
//                  B = reaction intensity, A = water vapour
// ============================================================
//
// fire.gdshader marches the tile atlas the solver writes. Everything but the
// march loop — the ray setup, the depth clamp and the emission/absorption model —
// lives here.

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// Half-res scene distance published by FireSceneDistance. Only read when the
// volume is marched in its own SubViewport, whose depth buffer holds nothing but
// the volume itself (Phase 6 item 1).
uniform sampler2D scene_distance_tex : filter_nearest;
uniform bool external_scene_depth = false;
// Screen-space water surface (lot H). The fluid renderer's filtered depth is a
// linear eye depth packed RG = floor + fract (0 = no surface); the thickness
// prepass feeds the same Beer-Lambert term the water composite applies to the
// scene behind it. Nearest on the depth: bilinear over a floor+fract packing
// would blend across integer boundaries.
uniform sampler2D water_depth_tex : filter_nearest, repeat_disable;
uniform sampler2D water_thickness_tex : filter_linear, repeat_disable;
uniform bool water_composite_on = false;
uniform vec3 water_absorption = vec3(0.55, 0.18, 0.09);
uniform float water_absorption_scale = 0.25;
// Hearth light for the smoke scatter term (lot J). The RGB carries
// colour * energy * strength already scaled by the host each frame, flicker
// included, so the volumetric smoke flickers with the OmniLight3D.
uniform vec3 fire_light_pos = vec3(0.0, 2.5, 0.0);
uniform vec3 fire_light_rgb = vec3(0.0);
// 0 taps keeps the flat unshaded smoke; 1/2 add volume taps between the sample
// and the light for self-shadowing.
uniform int smoke_light_taps : hint_range(0, 2) = 0;
// Flat grey fill of the smoke, and the daylight term on top of it. sun_rgb is
// colour * energy; 0 skips the sun branch and leaves the fill alone. The sun's
// self-shadow is taken by the caller from sun_shadow_taps samples along sun_dir.
uniform vec3 smoke_ambient_rgb = vec3(0.0875, 0.084, 0.0805);
uniform vec3 smoke_albedo = vec3(0.25, 0.24, 0.23);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_rgb = vec3(0.0);
uniform int sun_shadow_taps : hint_range(0, 6) = 0;
uniform float sun_shadow_length = 8.0;
// 1 = blue-noise offset of the shadow taps over a full tap step, 0 = taps at mid-step.
uniform float sun_jitter_strength : hint_range(0.0, 1.0) = 1.0;
uniform float sun_phase_g : hint_range(-0.9, 0.9) = 0.0;
uniform bool animated_jitter = true;

uniform vec3 box_size = vec3(6.4, 9.6, 6.4);
// Temperature the volume's red channel is normalised against, so the blackbody
// ramp reconstructs kelvins rather than assuming a range.
uniform float ambient_temperature = 300.0;
uniform float display_temperature = 2600.0;
// Linear radiance of a blackbody at display_temperature: the brightest value the volume can emit.
uniform float emission_strength : hint_range(0.5, 24.0) = 8.0;
// Window of emission temperature, in kelvin, over which the glow fades in: none below glow_visible_from_k,
// full from glow_visible_full_k. Both 0 = no fade. Cold soot stops glowing near 800 K (Draper point).
uniform float glow_visible_from_k = 0.0;
uniform float glow_visible_full_k = 0.0;
// Absorption of the hot gas per metre at full flame temperature (soot has smoke_absorption).
uniform float flame_absorption : hint_range(0.0, 10.0) = 2.5;
uniform float smoke_absorption : hint_range(0.0, 20.0) = 9.0;
uniform float steam_strength : hint_range(0.0, 20.0) = 6.0;
uniform float steam_absorption : hint_range(0.0, 20.0) = 4.0;
uniform float blue_strength : hint_range(0.0, 3.0) = 0.7;
// Height over which the blue reaction core fades out, in metres above the ground.
// This used to be the box height, which the virtual grid is not: its domain is
// 102 m tall and every flame base in it would read as blue. Set to a
// burner-sized domain height by the controller.
uniform float blue_height = 19.2;
uniform float noise_scale : hint_range(0.05, 1.0) = 0.35;
uniform float scroll_speed : hint_range(0.0, 3.0) = 1.2;
// Scales the density modulation of the detail noise; 1 is the original look.
uniform float noise_detail : hint_range(0.0, 6.0) = 1.0;
// 0 = shaded, 1 = peak normalised temperature, 2 = peak reaction, 3 = peak blue
// contribution (the term the shaded mode actually adds), 4 = emission-weighted
// temperature the ray shows.
uniform int debug_mode : hint_range(0, 4) = 0;
// Render-time billow detail (static world-space noise): 0 off, 1 erode,
// 2 erode + crevice cooling of the emission temperature, 3 = 2 + crevice soot.
uniform int billow_mode : hint_range(0, 3) = 0;
uniform float billow_strength : hint_range(0.0, 1.0) = 1.0;
// Fraction of the emission temperature removed in a full crevice.
uniform float billow_cool : hint_range(0.0, 0.9) = 0.3;
// Extra soot absorption in a full crevice, as a fraction of the soot term.
uniform float billow_soot : hint_range(0.0, 4.0) = 1.5;
// Longest octave wavelength: 8 cells of the explosion grid (0.2 m).
uniform float billow_wavelength_m = 1.6;
// Vertical lattice scale: 0.4 stretches every feature 2.5x along y into licks.
uniform float billow_stretch_y : hint_range(0.05, 1.0) = 1.0;
// Erosion ramp with height above the ground: strength is billow_rise_base at
// the ground and 1 at billow_rise_m (0 = constant strength).
uniform float billow_rise_m = 0.0;
uniform float billow_rise_base : hint_range(0.0, 1.0) = 0.3;
// Strength fades in with the normalised temperature: 0 below billow_fade_start, full from
// billow_fade_full (0 and 0 = no fade). Cold translucent smoke would otherwise show the crease sheets as veins.
uniform float billow_fade_start : hint_range(0.0, 1.0) = 0.0;
uniform float billow_fade_full : hint_range(0.0, 1.0) = 0.0;

varying vec3 cam_obj;
varying vec3 pos_obj;

// Blackbody chromaticity: Planck's law (Nguyen 2002 Eq. 22) integrated against the CIE 1931
// observer (Wyman 2013 fit), von Kries-adapted to the 2800 K white (Eq. 23) and normalised to a
// unit maximum channel. 15 stops, 700..2800 K at 150 K; tmp/fire_realism/planck_lut.py regenerates them.
const vec3 BLACKBODY_RGB[15] = vec3[](
	vec3(1.000, 0.051, 0.000), vec3(1.000, 0.083, 0.000), vec3(1.000, 0.130, 0.000),
	vec3(1.000, 0.187, 0.000), vec3(1.000, 0.251, 0.000), vec3(1.000, 0.319, 0.009),
	vec3(1.000, 0.391, 0.045), vec3(1.000, 0.466, 0.098), vec3(1.000, 0.543, 0.167),
	vec3(1.000, 0.620, 0.256), vec3(1.000, 0.698, 0.365), vec3(1.000, 0.775, 0.494),
	vec3(1.000, 0.852, 0.644), vec3(1.000, 0.927, 0.812), vec3(1.000, 1.000, 1.000));

vec3 blackbody_chroma(float T_kelvin) {
	float f = clamp((T_kelvin - 700.0) / 150.0, 0.0, 13.999);
	int i = int(f);
	return mix(BLACKBODY_RGB[i], BLACKBODY_RGB[i + 1], f - float(i));
}

// Kirchhoff: radiance emitted by a unit of absorption. Chromaticity from Planck, luminance
// (T / T_display)^4 (Stefan-Boltzmann) times the linear peak value emission_strength.
vec3 blackbody_radiance(float T_kelvin) {
	float ratio = T_kelvin / display_temperature;
	float r2 = ratio * ratio;
	float visible = glow_visible_full_k > glow_visible_from_k
		? smoothstep(glow_visible_from_k, glow_visible_full_k, T_kelvin) : 1.0;
	return blackbody_chroma(T_kelvin) * (r2 * r2 * emission_strength * visible);
}

void vertex() {
	pos_obj = VERTEX;
	cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// Ray/AABB slab test in object space. Returns false when the ray misses the box
// or the whole span is behind the camera.
bool box_span(vec3 ray_origin, vec3 ray_dir, vec3 lo, vec3 hi, out float t0, out float t1) {
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_a = (lo - ray_origin) * inv_dir;
	vec3 t_b = (hi - ray_origin) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	t0 = max(max(max(t_near.x, t_near.y), t_near.z), 0.0);
	t1 = min(min(t_far.x, t_far.y), t_far.z);
	return t1 > t0;
}

// Distance from the camera to the opaque geometry behind this pixel, so the
// volume stops at whatever occludes it. Forward+ is reversed-Z: the NDC z is the
// raw depth in [0,1]. Built-ins are passed in because this is not fragment().
float scene_depth_distance(vec2 screen_uv, mat4 inv_projection, mat4 inv_view, vec3 camera_world) {
	if (external_scene_depth) {
		return texture(scene_distance_tex, screen_uv).r;
	}
	float depth_raw = texture(depth_texture, screen_uv).r;
	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = inv_projection * ndc;
	view_pos.xyz /= view_pos.w;
	vec3 world_scene = (inv_view * vec4(view_pos.xyz, 1.0)).xyz;
	// Model has no scale: object-space t equals world-space distance
	return distance(world_scene, camera_world);
}

// Where the water surface sits along this pixel's ray, in the same t the march
// measures. The fluid depth is an eye depth (view -z), so one divide by the
// cosine against the camera axis converts it; the box meshes carry no rotation,
// which is the same assumption the grid mapping already makes.
float water_ray_distance(vec2 screen_uv, vec3 ray_dir, mat4 inv_view) {
	if (!water_composite_on) {
		return 1e9;
	}
	vec2 packed = texture(water_depth_tex, screen_uv).rg;
	float eye_depth = packed.x + packed.y;
	if (eye_depth <= 0.001) {
		return 1e9;
	}
	vec3 forward = normalize((inv_view * vec4(0.0, 0.0, -1.0, 0.0)).xyz);
	float cos_angle = dot(ray_dir, forward);
	if (cos_angle <= 1e-4) {
		return 1e9;
	}
	return eye_depth / cos_angle;
}

// Per-channel Beer-Lambert of the water column, the same absorption the water
// composite applies to the scene it refracts.
vec3 water_transmittance(vec2 uv) {
	float thickness = texture(water_thickness_tex, uv).r;
	return exp(-water_absorption * thickness * water_absorption_scale);
}

// 64x64 void-and-cluster blue noise (tools/gen_blue_noise.py), fetched by pixel
// modulo 64. jitter_phase is the host's per-frame golden-ratio offset; the
// animated_jitter switch freezes it, since a fixed pattern is what a march/jitter
// comparison and reproducible capture sequences need.
uniform sampler2D blue_noise_tex : filter_nearest, repeat_enable;
uniform float jitter_phase = 0.0;

float blue_noise_jitter(vec2 fragcoord, ivec2 shift) {
	float bn = texelFetch(blue_noise_tex, (ivec2(fragcoord) + shift) & ivec2(63), 0).r;
	return fract(bn + (animated_jitter ? jitter_phase : 0.0));
}

float march_jitter(vec2 fragcoord) {
	return blue_noise_jitter(fragcoord, ivec2(0));
}

vec3 billow_hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx) * 2.0 - 1.0;
}

float billow_gradient_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = p - i;
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float g000 = dot(billow_hash(i), f);
	float g100 = dot(billow_hash(i + vec3(1.0, 0.0, 0.0)), f - vec3(1.0, 0.0, 0.0));
	float g010 = dot(billow_hash(i + vec3(0.0, 1.0, 0.0)), f - vec3(0.0, 1.0, 0.0));
	float g110 = dot(billow_hash(i + vec3(1.0, 1.0, 0.0)), f - vec3(1.0, 1.0, 0.0));
	float g001 = dot(billow_hash(i + vec3(0.0, 0.0, 1.0)), f - vec3(0.0, 0.0, 1.0));
	float g101 = dot(billow_hash(i + vec3(1.0, 0.0, 1.0)), f - vec3(1.0, 0.0, 1.0));
	float g011 = dot(billow_hash(i + vec3(0.0, 1.0, 1.0)), f - vec3(0.0, 1.0, 1.0));
	float g111 = dot(billow_hash(i + vec3(1.0, 1.0, 1.0)), f - vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(g000, g100, u.x), mix(g010, g110, u.x), u.y),
		mix(mix(g001, g101, u.x), mix(g011, g111, u.x), u.y), u.z);
}

// Signed fbm of 3 octaves (wavelength L, L/2, L/4, amplitude ratio 0.5), each on a
// rotated lattice, scaled to roughly [-1, 1].
// The crease band |f| < 1 / BILLOW_CREASE_GAIN is ~0.1 L wide, so the wavelength
// is floored at 2 gain march steps (ds_m, metres) to keep it at least one step.
const float BILLOW_CREASE_GAIN = 5.0;

float billow_signed(vec3 world_p, float ds_m) {
	const mat3 rot = mat3(vec3(0.36, 0.48, -0.8), vec3(-0.8, 0.6, 0.0),
		vec3(0.48, 0.64, 0.6));
	vec3 q = world_p / max(billow_wavelength_m, 2.0 * BILLOW_CREASE_GAIN * ds_m);
	q.y *= billow_stretch_y;
	float sum = 0.0;
	float amp = 1.0;
	for (int i = 0; i < 3; i++) {
		sum += amp * billow_gradient_noise(q + vec3(17.3, 9.1, 31.7) * float(i));
		q = rot * q * 2.0;
		amp *= 0.5;
	}
	return sum / 1.75;
}

// Billow height in 0..1: |fbm|. Lobes are round, creases (0) lie on the zero set
// of the fbm.
float billow_height(vec3 world_p, float ds_m) {
	return clamp(abs(billow_signed(world_p, ds_m)) * BILLOW_CREASE_GAIN, 0.0, 1.0);
}

// The same height with the lattice carried by the flow: the fbm is read at the rest
// position x + d of two lattices (d1, d2) and blended by their weights w with the
// variance-preserving rule (w1 n1 + w2 n2) / |w| (Neyret 2003), so the contrast does
// not dip where both weigh the same. Without any weight it is the static lattice.
float billow_height_rest(vec3 world_p, vec3 d1, vec3 d2, vec2 w, float ds_m) {
	float norm = length(w);
	if (norm < 1e-4) {
		return billow_height(world_p, ds_m);
	}
	float n = 0.0;
	if (w.x > 1e-3 * norm) {
		n += w.x * billow_signed(world_p + d1, ds_m);
	}
	if (w.y > 1e-3 * norm) {
		n += w.y * billow_signed(world_p + d2, ds_m);
	}
	return clamp(abs(n / norm) * BILLOW_CREASE_GAIN, 0.0, 1.0);
}

// Temperature the emission is evaluated at: the solver's, cooled in the crevices
// by mode 2 and 3 only (never hotter).
float billow_emission_temperature(vec4 s, float bh, float strength) {
	float T_kelvin = ambient_temperature
		+ s.r * (display_temperature - ambient_temperature);
	if (billow_mode >= 2 && strength > 0.0 && s.r + s.g > 0.01) {
		T_kelvin *= 1.0 - billow_cool * strength * (1.0 - bh);
	}
	return T_kelvin;
}

float billow_strength_at(float height, float t_norm) {
	float strength = billow_strength;
	if (billow_fade_full > billow_fade_start) {
		strength *= smoothstep(billow_fade_start, billow_fade_full, t_norm);
	}
	if (billow_rise_m <= 0.0) {
		return strength;
	}
	return strength * mix(billow_rise_base, 1.0, smoothstep(0.0, billow_rise_m, height));
}

// One front-to-back sample of the volume. [param p] is the sample point in
// object space, [param world_p] the same point in world space — the noise is
// keyed off the world position, so moving the display proxy does not drag the
// pattern with it — and [param height] the height above the ground.
// [param light_tap_a/b] are volume samples between p and the hearth light,
// evaluated by the caller (it owns the field sampling); [param light_dist] the
// (range-clamped) distance to that light.
// [param billow_h] is the billow height at this sample (1 when billows are off).
// [param sun_occl] is the transmittance toward the sun and [param sun_phase] the
// phase value for this ray, both evaluated by the caller.
void accumulate(vec4 s, vec3 p, vec3 world_p, float height, float ds, float time,
		vec4 light_tap_a, vec4 light_tap_b, float light_dist,
		float sun_occl, float sun_phase, float billow_h,
		inout vec3 col, inout float trans, out float blue_out) {
	blue_out = 0.0;
	// Steam. Only the cool part of the vapour field is drawn: water made by
	// combustion itself is superheated and optically nothing, while vapour
	// that has drifted out of the flame is the white cloud a hose produces.
	// Bright, forward-scattering and non-emissive, so it reads as steam
	// rather than as more smoke.
	float steam = s.a * (1.0 - smoothstep(0.05, 0.35, s.r)) * steam_strength;
	if (steam > 0.001) {
		col += trans * vec3(0.85, 0.88, 0.92) * steam * ds;
		trans *= exp(-steam * steam_absorption * ds);
	}

	if (s.r + s.g > 0.01) {
		// Detail noise modulates the density only: temperature stays the solver's, so
		// the T^4 emission cannot be eroded into speckle.
		// World space: keying the noise off the object-space point made the
		// pattern swim whenever the display proxy followed the resident tiles.
		vec3 np = world_p * noise_scale - vec3(0.0, time * scroll_speed, 0.0);
		float n = texture(noise_tex, np).r;
		float density_mod = mix(1.0, 0.85 + 0.3 * n, noise_detail);
		float t_eff = s.r;
		float T_kelvin = ambient_temperature
			+ t_eff * (display_temperature - ambient_temperature);

		// Blue core: strong reaction with low soot, flame base only
		float base_h = clamp(1.0 - height / blue_height, 0.0, 1.0);
		float reaction = min(s.b, 1.0);
		float blue = reaction * reaction * (1.0 - smoothstep(0.2, 0.5, s.g)) * base_h * base_h;
		vec3 emit = blue * vec3(0.25, 0.45, 1.0) * blue_strength;
		blue_out = blue;

		// Strict Kirchhoff (Pegoraro & Parker 2006 Eq. 1 without scattering; Eq. 3 per segment):
		// sigma_a = soot + gas(T), emitted radiance = sigma_a * B(T). A gas without
		// absorption emits nothing and soot absorbs exactly where it also glows, so a cold
		// soot shell is black and no dark rim forms around a flame.
		float w_gas = smoothstep(900.0, 1500.0, T_kelvin);
		float sigma_soot = s.g * smoke_absorption * density_mod;
		float sigma_gas = w_gas * flame_absorption * density_mod;
		float T_emit = T_kelvin;
		if (billow_mode > 0 && billow_strength > 0.0) {
			float bh = billow_h;
			float core = smoothstep(0.15, 0.7, max(s.r, s.g));
			float bs = billow_strength_at(height, s.r);
			float depth = bs * mix(1.0, 0.35, core);
			float keep = smoothstep(depth * 0.7 - 0.3, depth * 0.7, bh);
			if (billow_mode >= 3) {
				sigma_soot *= 1.0 + billow_soot * bs * (1.0 - bh);
			}
			sigma_soot *= keep;
			sigma_gas *= keep;
			T_emit = billow_emission_temperature(s, bh, bs);
		}
		float sigma = sigma_soot + sigma_gas;
		float seg = 1.0 - exp(-sigma * ds);
		col += trans * blackbody_radiance(T_emit) * seg;

		emit += smoke_ambient_rgb * s.g * (1.0 - t_eff) * density_mod;

		// Hearth-lit smoke on top of the flat ambient fill: grey keeps the
		// silhouette away from black, the light term gives the plume the
		// colour and the falloff of the fire it wraps. Self-shadowing comes
		// from the caller's taps; with 0 taps the term is unoccluded.
		float smoke_scatter = s.g * (1.0 - t_eff) * density_mod;
		if (smoke_scatter > 1e-4
				&& fire_light_rgb.r + fire_light_rgb.g + fire_light_rgb.b > 1e-5) {
			float r2 = dot(world_p - fire_light_pos, world_p - fire_light_pos);
			float occl = 1.0;
			if (smoke_light_taps == 1) {
				occl = exp(-smoke_absorption * light_tap_a.g * light_dist);
			} else if (smoke_light_taps == 2) {
				occl = exp(-smoke_absorption * (light_tap_a.g + light_tap_b.g)
					* light_dist * 0.5);
			}
			emit += smoke_scatter * fire_light_rgb * occl / (1.0 + r2 * 0.25);
		}
		if (smoke_scatter > 1e-4 && sun_rgb.r + sun_rgb.g + sun_rgb.b > 1e-5) {
			emit += smoke_scatter * smoke_albedo * sun_rgb * (sun_occl * sun_phase);
		}

		col += trans * emit * ds;
		trans *= 1.0 - seg;
	}
}

void accumulate(vec4 s, vec3 p, vec3 world_p, float height, float ds, float time,
		vec4 light_tap_a, vec4 light_tap_b, float light_dist,
		inout vec3 col, inout float trans, out float blue_out) {
	float bh = billow_mode > 0 && billow_strength > 0.0 && s.r + s.g > 0.01 ? billow_height(world_p, ds) : 1.0;
	accumulate(s, p, world_p, height, ds, time, light_tap_a, light_tap_b, light_dist,
		1.0, 1.0, bh, col, trans, blue_out);
}
