// ============================================================
// Fire volume raymarcher — shared body
// Inspired by Fire-X (Wrede et al., SIGGRAPH Asia 2025)
// Volume channels: R = normalized temperature, G = smoke/soot,
//                  B = reaction intensity, A = water vapour
// ============================================================
//
// Two shaders march the same volume: fire.gdshader over the dense box, and
// fire_sparse.gdshader over the tile atlas the sparse solver writes. Only the
// march differs — the ray setup, the depth clamp and the emission/absorption
// model are identical — so everything but the loop lives here and neither shader
// can drift away from the other's look.

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

uniform vec3 box_size = vec3(6.4, 9.6, 6.4);
// Temperature the volume's red channel is normalised against, so the blackbody
// ramp reconstructs kelvins rather than assuming a range.
uniform float ambient_temperature = 300.0;
uniform float display_temperature = 2600.0;
uniform float emission_strength : hint_range(0.5, 12.0) = 3.0;
uniform float flame_absorption : hint_range(0.0, 10.0) = 2.5;
uniform float smoke_absorption : hint_range(0.0, 20.0) = 9.0;
uniform float steam_strength : hint_range(0.0, 20.0) = 6.0;
uniform float steam_absorption : hint_range(0.0, 20.0) = 4.0;
uniform float blue_strength : hint_range(0.0, 3.0) = 0.7;
// Height over which the blue reaction core fades out, in metres above the ground.
// This used to be the box height, which the sparse grid is not: its domain is
// 102 m tall and every flame base in it would read as blue. Set to the dense
// domain height by the controller, so both builds keep the same falloff.
uniform float blue_height = 19.2;
uniform float noise_scale : hint_range(0.05, 1.0) = 0.35;
uniform float scroll_speed : hint_range(0.0, 3.0) = 1.2;
uniform int debug_mode : hint_range(0, 1) = 0;

varying vec3 cam_obj;
varying vec3 pos_obj;

// Fire color ramp, approximate blackbody (Fire-X Fig. 4/5)
vec3 fire_ramp(float T_kelvin) {
	vec3 c = vec3(0.0);
	// Stops span the range the solver actually reaches now that it runs in real
	// kelvins: embers near 800 K through to a near-white 2800 K flame core.
	c = mix(c, vec3(0.85, 0.04, 0.0), smoothstep(700.0, 1100.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.35, 0.02), smoothstep(1100.0, 1600.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.75, 0.12), smoothstep(1600.0, 2200.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.96, 0.85), smoothstep(2200.0, 2800.0, T_kelvin));
	return c;
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
	float depth_raw = texture(depth_texture, screen_uv).r;
	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = inv_projection * ndc;
	view_pos.xyz /= view_pos.w;
	vec3 world_scene = (inv_view * vec4(view_pos.xyz, 1.0)).xyz;
	// Model has no scale: object-space t equals world-space distance
	return distance(world_scene, camera_world);
}

// One front-to-back sample of the volume. [param p] is the sample point in object
// space (the noise is keyed off it), [param height] its height above the ground.
void accumulate(vec4 s, vec3 p, float height, float ds, float time,
		inout vec3 col, inout float trans) {
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
		// Detail noise: density modulation + edge erosion of temperature.
		// Kept subtle — the simulation resolves the turbulence itself now,
		// and heavy erosion would only smear the structure it produces.
		vec3 np = p * noise_scale - vec3(0.0, time * scroll_speed, 0.0);
		float n = texture(noise_tex, np).r;
		float n2 = texture(noise_tex, np * 2.1 + vec3(0.37, 0.11, 0.73)).r;
		float density_mod = 0.85 + 0.3 * n;
		float t_eff = s.r * (0.9 + 0.2 * n2);

		// Emission: blackbody ramp. Hot thin gas (cubic core bloom) plus
		// glowing soot — incandescent smoke IS the visible orange flame
		float T_kelvin = ambient_temperature
			+ t_eff * (display_temperature - ambient_temperature);
		vec3 bb = fire_ramp(T_kelvin);
		float emit_density = pow(t_eff, 3.0) + s.g * t_eff * 0.8;
		vec3 emit = bb * emit_density * emission_strength;

		// Blue core: strong reaction with low soot, flame base only
		float base_h = clamp(1.0 - height / blue_height, 0.0, 1.0);
		float blue = s.b * s.b * (1.0 - smoothstep(0.2, 0.5, s.g)) * base_h * base_h;
		emit += blue * vec3(0.25, 0.45, 1.0) * blue_strength;

		// Smoke: Beer-Lambert extinction + faint gray scatter for cool smoke
		float sigma = (s.g * smoke_absorption + t_eff * flame_absorption) * density_mod;
		emit += vec3(0.25, 0.24, 0.23) * s.g * (1.0 - t_eff) * 0.35 * density_mod;

		col += trans * emit * ds;
		trans *= exp(-sigma * ds);
	}
}
