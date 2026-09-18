shader_type spatial;
// Volume raymarcher over the dense fire simulation grid (Texture3D).
// cull_front: rendering the box back faces keeps the volume visible
// when the camera enters it. blend_mix (not additive) so smoke can darken.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

#include "res://shaders/fire/fire_volume.gdshaderinc"

// The whole domain, one texel per cell. The sparse build's field is a tile atlas
// instead and needs the indirection to read; see fire_sparse.gdshader.
uniform sampler3D volume_tex : filter_linear, repeat_disable;
uniform sampler3D volume_tex_prev : filter_linear, repeat_disable;
uniform float temporal_blend = 1.0;
uniform float march_step : hint_range(0.25, 4.0) = 0.75;
uniform float max_distance = 80.0;
uniform int march_budget : hint_range(64, 512) = 320;

vec4 light_sample(vec3 p_obj, vec3 light_obj, float frac) {
	vec3 target = mix(p_obj, light_obj, frac);
	return texture(volume_tex, target / box_size + 0.5);
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);
	vec3 half_size = box_size * 0.5;

	float t0;
	float t1;
	if (!box_span(cam_obj, ray_dir, -half_size, half_size, t0, t1)) {
		discard;
	}
	t1 = min(t1, t0 + max_distance);

	// ---- Scene depth clamp (opaque geometry occludes the volume) ----
	t1 = min(t1, scene_depth_distance(SCREEN_UV, INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX, CAMERA_POSITION_WORLD));
	if (t1 <= t0) {
		discard;
	}

	// Water plane split, same contract as the sparse marcher (lot H).
	float t_water = water_ray_distance(SCREEN_UV, ray_dir, INV_VIEW_MATRIX);
	vec3 water_tw = water_transmittance(SCREEN_UV);
	vec3 light_obj = (inverse(MODEL_MATRIX) * vec4(fire_light_pos, 1.0)).xyz;

	// ---- Raymarch, front to back ----
	// The volume now carries real structure at 0.1 m per cell; undersampling it
	// aliases the flame front into banding the jitter cannot hide.
	int steps = min(march_budget, max(1, int(ceil(60.0 / march_step))));
	float ds = (t1 - t0) / float(steps);
	// Interleaved gradient noise jitter breaks banding; animation optional.
	float jitter = march_jitter(FRAGCOORD.xy);
	float t = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float debug_max = 0.0;
	vec3 col_front = vec3(0.0);
	float trans_front = 1.0;
	bool crossed_water = false;

	for (int i = 0; i < march_budget; i++) {
		if (i >= steps) {
			break;
		}
		vec3 p = cam_obj + ray_dir * t;
		vec3 world_p = (MODEL_MATRIX * vec4(p, 1.0)).xyz;
		vec3 volume_uv = p / box_size + 0.5;
		vec4 s = texture(volume_tex, volume_uv);
		if (temporal_blend < 0.999) {
			s = mix(texture(volume_tex_prev, volume_uv), s, temporal_blend);
		}

		if (!crossed_water && t >= t_water) {
			crossed_water = true;
			col_front = col;
			trans_front = trans;
		}

		if (debug_mode == 1) {
			debug_max = max(debug_max, s.r);
		} else {
			vec4 light_a = vec4(0.0);
			vec4 light_b = vec4(0.0);
			float light_dist = 0.0;
			if (smoke_light_taps > 0 && s.g > 0.001
					&& fire_light_rgb.r + fire_light_rgb.g + fire_light_rgb.b > 1e-5) {
				light_dist = min(distance(world_p, fire_light_pos), 8.0);
				light_a = light_sample(p, light_obj, smoke_light_taps == 1 ? 0.5 : 0.33);
				if (smoke_light_taps == 2) {
					light_b = light_sample(p, light_obj, 0.66);
				}
			}
			float blue = 0.0;
			accumulate(s, p, world_p, p.y + half_size.y, ds, TIME, light_a,
				light_b, light_dist, col, trans, blue);
			if (debug_mode == 2) {
				debug_max = max(debug_max, s.b);
			} else if (debug_mode == 3) {
				debug_max = max(debug_max, blue);
			}
			if (trans < 0.01) {
				break;
			}
		}
		t += ds;
	}

	if (debug_mode >= 1) {
		ALBEDO = vec3(debug_max);
		ALPHA = debug_max > 0.005 ? 0.85 : 0.0;
	} else if (crossed_water) {
		// Same composite contract as the sparse marcher: alpha carries the
		// front transmittance, the behind-plane fire returns through the
		// water's own extinction.
		float a = max(1.0 - trans_front, 0.02);
		vec3 behind = col - col_front;
		ALBEDO = (col_front + trans_front * water_tw * behind) / a;
		ALPHA = a;
	} else {
		float alpha = 1.0 - trans;
		ALBEDO = col / max(alpha, 1e-4);
		ALPHA = alpha;
	}
}
