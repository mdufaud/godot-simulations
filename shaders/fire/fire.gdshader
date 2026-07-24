shader_type spatial;
// Volume raymarcher over the dense fire simulation grid (Texture3D).
// cull_front: rendering the box back faces keeps the volume visible
// when the camera enters it. blend_mix (not additive) so smoke can darken.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

#include "res://shaders/fire/fire_volume.gdshaderinc"

// The whole domain, one texel per cell. The sparse build's field is a tile atlas
// instead and needs the indirection to read; see fire_sparse.gdshader.
uniform sampler3D volume_tex : filter_linear, repeat_disable;

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);
	vec3 half_size = box_size * 0.5;

	float t0;
	float t1;
	if (!box_span(cam_obj, ray_dir, -half_size, half_size, t0, t1)) {
		discard;
	}

	// ---- Scene depth clamp (opaque geometry occludes the volume) ----
	t1 = min(t1, scene_depth_distance(SCREEN_UV, INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX, CAMERA_POSITION_WORLD));
	if (t1 <= t0) {
		discard;
	}

	// ---- Raymarch, front to back ----
	// The volume now carries real structure at 0.1 m per cell; undersampling it
	// aliases the flame front into banding the jitter cannot hide.
	const int STEPS = 80;
	float ds = (t1 - t0) / float(STEPS);
	// Interleaved gradient noise jitter breaks banding; TIME term animates it
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))) + TIME * 0.61);
	float t = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float debug_max = 0.0;

	for (int i = 0; i < STEPS; i++) {
		vec3 p = cam_obj + ray_dir * t;
		vec4 s = texture(volume_tex, p / box_size + 0.5);

		if (debug_mode == 1) {
			debug_max = max(debug_max, s.r);
		} else {
			accumulate(s, p, p.y + half_size.y, ds, TIME, col, trans);
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
