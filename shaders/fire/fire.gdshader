shader_type spatial;
// Volume raymarcher over the fire simulation grid (Texture3D).
// cull_front: rendering the box back faces keeps the volume visible
// when the camera enters it. blend_mix (not additive) so smoke can darken.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

// ============================================================
// Fire volume shader — raymarched emission/absorption
// Inspired by Fire-X (Wrede et al., SIGGRAPH Asia 2025)
// Volume channels: R = normalized temperature, G = smoke/soot,
//                  B = reaction intensity, A = fuel
// ============================================================

uniform sampler3D volume_tex : filter_linear, repeat_disable;
uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

uniform vec3 box_size = vec3(6.4, 9.6, 6.4);
uniform float emission_strength : hint_range(0.5, 12.0) = 6.5;
uniform float flame_absorption : hint_range(0.0, 10.0) = 2.5;
uniform float smoke_absorption : hint_range(0.0, 20.0) = 9.0;
uniform float blue_strength : hint_range(0.0, 3.0) = 0.7;
uniform float noise_scale : hint_range(0.05, 1.0) = 0.35;
uniform float scroll_speed : hint_range(0.0, 3.0) = 1.2;
uniform int debug_mode : hint_range(0, 1) = 0;

varying vec3 cam_obj;
varying vec3 pos_obj;

// Fire color ramp, approximate blackbody (Fire-X Fig. 4/5)
vec3 fire_ramp(float T_kelvin) {
	vec3 c = vec3(0.0);
	c = mix(c, vec3(0.85, 0.04, 0.0), smoothstep(600.0, 900.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.35, 0.02), smoothstep(900.0, 1150.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.75, 0.12), smoothstep(1150.0, 1450.0, T_kelvin));
	c = mix(c, vec3(1.0, 0.96, 0.85), smoothstep(1450.0, 1800.0, T_kelvin));
	return c;
}

void vertex() {
	pos_obj = VERTEX;
	cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);

	// ---- Ray/AABB slab test (object space, box centered at origin) ----
	vec3 half_size = box_size * 0.5;
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_a = (-half_size - cam_obj) * inv_dir;
	vec3 t_b = (half_size - cam_obj) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	float t0 = max(max(t_near.x, t_near.y), t_near.z);
	float t1 = min(min(t_far.x, t_far.y), t_far.z);
	t0 = max(t0, 0.0);

	// ---- Scene depth clamp (opaque geometry occludes the volume) ----
	// Forward+ reversed-Z: NDC z = raw depth in [0,1]
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = INV_PROJECTION_MATRIX * ndc;
	view_pos.xyz /= view_pos.w;
	vec3 world_scene = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
	// Model has no scale: object-space t equals world-space distance
	float t_scene = distance(world_scene, CAMERA_POSITION_WORLD);
	t1 = min(t1, t_scene);

	if (t1 <= t0) {
		discard;
	}

	// ---- Raymarch, front to back ----
	const int STEPS = 48;
	float ds = (t1 - t0) / float(STEPS);
	// Interleaved gradient noise jitter breaks banding; TIME term animates it
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))) + TIME * 0.61);
	float t = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float debug_max = 0.0;

	for (int i = 0; i < STEPS; i++) {
		vec3 p = cam_obj + ray_dir * t;
		vec3 uvw = p / box_size + 0.5;
		vec4 s = texture(volume_tex, uvw);

		if (debug_mode == 1) {
			debug_max = max(debug_max, s.r);
			t += ds;
			continue;
		}

		if (s.r + s.g > 0.01) {
			// Detail noise: density modulation + edge erosion of temperature
			vec3 np = p * noise_scale - vec3(0.0, TIME * scroll_speed, 0.0);
			float n = texture(noise_tex, np).r;
			float n2 = texture(noise_tex, np * 2.1 + vec3(0.37, 0.11, 0.73)).r;
			float density_mod = 0.6 + 0.8 * n;
			float t_eff = s.r * (0.75 + 0.5 * n2);

			// Emission: blackbody ramp. Hot thin gas (cubic core bloom) plus
			// glowing soot — incandescent smoke IS the visible orange flame
			float T_kelvin = 293.0 + t_eff * 1507.0;
			vec3 bb = fire_ramp(T_kelvin);
			float emit_density = pow(t_eff, 3.0) + s.g * t_eff * 0.8;
			vec3 emit = bb * emit_density * emission_strength;

			// Blue core: strong reaction with low soot, flame base only
			float base_h = 1.0 - uvw.y;
			float blue = s.b * s.b * (1.0 - smoothstep(0.2, 0.5, s.g)) * base_h * base_h;
			emit += blue * vec3(0.25, 0.45, 1.0) * blue_strength;

			// Smoke: Beer-Lambert extinction + faint gray scatter for cool smoke
			float sigma = (s.g * smoke_absorption + t_eff * flame_absorption) * density_mod;
			emit += vec3(0.25, 0.24, 0.23) * s.g * (1.0 - t_eff) * 0.35 * density_mod;

			col += trans * emit * ds;
			trans *= exp(-sigma * ds);

			if (trans < 0.01) {
				break;
			}
		}
		t += ds;
	}

	if (debug_mode == 1) {
		ALBEDO = vec3(debug_max);
		ALPHA = debug_max > 0.005 ? 0.85 : 0.0;
	} else {
		float alpha = 1.0 - trans;
		ALBEDO = col / max(alpha, 1e-4);
		ALPHA = alpha;
	}
}
