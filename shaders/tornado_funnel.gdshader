shader_type spatial;
// Raymarched tornado condensation funnel. Same skeleton as fire.gdshader:
// cull_front keeps the volume visible from inside, blend_mix lets it darken the sky.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled, fog_disabled;

#include "res://shaders/tornado_wind.gdshaderinc"

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

uniform vec3 box_size = vec3(200.0, 550.0, 200.0);
uniform int steps : hint_range(16, 96) = 48;
uniform float dust_density : hint_range(0.0, 2.0) = 1.0;
uniform float darkness : hint_range(0.0, 1.0) = 0.55;
uniform float skirt_density : hint_range(0.0, 2.0) = 1.0;
uniform vec3 funnel_color : source_color = vec3(0.3, 0.31, 0.36);
uniform vec3 dust_color : source_color = vec3(0.55, 0.42, 0.28);
uniform vec3 sun_dir = vec3(-0.5, 0.0, -0.6);
uniform float swirl_vis : hint_range(0.0, 3.0) = 1.0;
uniform float noise_scale : hint_range(0.001, 0.05) = 0.008;
uniform float absorption : hint_range(0.5, 8.0) = 6.0;
uniform int storm_type = 0; // 0 normal, 1 fire, 2 water, 3 ice, 4 plasma
uniform int skirt_style = 0; // 0 debris storm, 1 multi-vortex, 2 shockwaves
uniform float glow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float flash_intensity = 0.0;
uniform vec3 flash_pos = vec3(0.0, 200.0, 0.0);
uniform float flash_radius = 140.0;
uniform vec3 flash_color : source_color = vec3(0.8, 0.85, 1.0);

// Approximate blackbody ramp (same family as fire.gdshader).
vec3 fire_ramp(float t_kelvin) {
	vec3 c = vec3(0.0);
	c = mix(c, vec3(0.85, 0.04, 0.0), smoothstep(600.0, 900.0, t_kelvin));
	c = mix(c, vec3(1.0, 0.35, 0.02), smoothstep(900.0, 1150.0, t_kelvin));
	c = mix(c, vec3(1.0, 0.75, 0.12), smoothstep(1150.0, 1450.0, t_kelvin));
	c = mix(c, vec3(1.0, 0.96, 0.85), smoothstep(1450.0, 1800.0, t_kelvin));
	return c;
}

// Sparse animated glints for ice crystals / plasma stars.
float sparkle(vec3 wp) {
	float s = texture(noise_tex, wp * 0.045 + vec3(0.0, TIME * 0.04, 0.0)).r;
	float s2 = texture(noise_tex, wp * 0.021 + vec3(31.7, TIME * 0.02, 8.3)).r;
	return smoothstep(0.74, 0.85, s * s2 * 1.6);
}

// Glints rotating rigidly with the vortex — static glints kill the sense of spin.
float sparkle_spin(vec3 wp, vec3 cs, float rc) {
	float om = swirl_sign * (u_max / max(rc, 1.0)) * 0.3 * TIME;
	float ca = cos(om);
	float sa = sin(om);
	vec2 rel = wp.xz - cs.xz;
	vec2 rr = vec2(ca * rel.x - sa * rel.y, sa * rel.x + ca * rel.y);
	return sparkle(vec3(rr.x + cs.x, wp.y, rr.y + cs.z));
}

varying vec3 cam_obj;
varying vec3 pos_obj;
varying vec3 model_origin;

void vertex() {
	pos_obj = VERTEX;
	cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	model_origin = MODEL_MATRIX[3].xyz;
}

// Funnel density at world position. Wall peak just inside the core radius,
// hazy interior, ground dust skirt; FBM sheared by the model's own rotation profile.
float funnel_density(vec3 wp, out float skirt_w, out float turb_out) {
	float y01 = wp.y / funnel_height;
	vec3 c = tw_centerline(wp.y);
	float rc = tw_core_radius(wp.y);
	vec2 rel = wp.xz - c.xz;
	float r = length(rel);
	float r_bar = r / max(rc, 1e-3);

	// Differential rotation: inner noise spins fast, outer slow — the shear
	// is what reads as a real vortex instead of a rotating cylinder.
	float ang = atan(rel.y, rel.x);
	// Shear divisor clamped at 0.3: unbounded inner spin smears the noise into
	// concentric rings near the axis (moire through both walls).
	float shear = swirl_sign * swirl_vis * (u_max / max(rc, 1.0)) * tw_v_theta(max(r_bar, 0.05)) / max(r_bar, 0.3);
	float a = ang - TIME * shear * 0.35;
	// Vertical stretch (x0.3) elongates the noise into the striations real funnels show.
	vec3 np = vec3(cos(a) * r, (wp.y - TIME * u_max * 0.25) * 0.3, sin(a) * r) * noise_scale;
	float n = texture(noise_tex, np).r;
	float n2 = texture(noise_tex, np * 2.1 + vec3(0.37, 0.11, 0.73)).r;
	float turb = 0.4 + 1.1 * (n * 0.65 + n2 * 0.35);
	turb_out = turb;

	// Noise-wobbled wall radius: breaks the perfect cone silhouette.
	float rw = r_bar + 0.25 * (n - 0.5);
	float wall = exp(-pow((rw - 0.85) / 0.25, 2.0));
	float fill = 0.1 * (1.0 - smoothstep(0.0, 1.0, r_bar));
	float body = (wall + fill) * smoothstep(0.0, 0.06, y01);
	// Slight top fade only — the cloud deck hides the junction.
	body *= 1.0 - 0.5 * smoothstep(0.94, 1.0, y01);

	// ── Ground skirt: dust churned FROM the ground — dense at y=0, exponential
	// falloff upward. The density slider SPREADS the apron outward (low and wide,
	// never a ball); opacity is capped so the funnel always stays visible.
	float rr0 = r / max(r_core0, 1e-3);
	float outer = 3.0 + 1.2 * skirt_density;
	float h_scale = 0.05 * funnel_height * (1.0 + 0.6 * smoothstep(outer, 0.5, rr0));
	float ground_hug = exp(-wp.y / max(h_scale, 1.0));
	float skirt_base = smoothstep(outer, 0.4, rr0);
	float churn = 0.3 + 1.1 * n;
	// Angular surge lobes rolling around the base.
	float lobes = 1.0 + 0.45 * sin(ang * 4.0 - TIME * 1.3 * swirl_sign + rr0 * 2.5);
	float sk = 0.0;
	if (skirt_style == 1) {
		// Satellite suction vortices: helical columns corkscrewing around the
		// main funnel, leaning outward with height — not straight pylons.
		sk = ground_hug * skirt_base * churn * 0.5;
		float col_h = exp(-wp.y / max(0.14 * funnel_height, 1.0));
		float twist = swirl_sign * 0.010 * wp.y;
		for (int v = 0; v < 5; v++) {
			float ph = TIME * 0.55 * swirl_sign + float(v) * 1.2566371 + twist;
			float orbit = r_core0 * (1.5 + 0.4 * sin(TIME * 0.8 + float(v) * 2.1))
				+ wp.y * 0.3 + r_core0 * 0.3 * (n - 0.5);
			vec2 vc = c.xz + vec2(cos(ph), sin(ph)) * orbit;
			float w = 0.28 * r_core0 * (1.0 + wp.y / max(0.14 * funnel_height, 1.0));
			float dv = length(wp.xz - vc) / max(w, 1.0);
			sk += col_h * exp(-dv * dv) * (0.7 + 0.8 * n) * 2.4;
		}
	} else if (skirt_style == 2) {
		// Dust shockwave rings blasting outward, flattening as they expand.
		sk = ground_hug * skirt_base * churn * 0.5;
		for (int w = 0; w < 3; w++) {
			float phase = fract(TIME * 0.16 + float(w) * 0.3333);
			float dr_ring = (rr0 - 0.4 - phase * (outer - 0.5)) / 0.3;
			float ring_hug = exp(-wp.y / max(0.05 * funnel_height * (1.0 - 0.55 * phase), 1.0));
			sk += ring_hug * exp(-dr_ring * dr_ring) * (1.0 - phase * phase) * (0.7 + 0.7 * n) * 2.0;
		}
	} else {
		sk = ground_hug * skirt_base * churn * lobes;
	}
	skirt_w = min(skirt_density * sk, 2.4);
	return (body * dust_density + skirt_w) * turb;
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);

	vec3 half_size = box_size * 0.5;
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_a = (-half_size - cam_obj) * inv_dir;
	vec3 t_b = (half_size - cam_obj) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	float t0 = max(max(t_near.x, t_near.y), t_near.z);
	float t1 = min(min(t_far.x, t_far.y), t_far.z);
	t0 = max(t0, 0.0);

	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = INV_PROJECTION_MATRIX * ndc;
	view_pos.xyz /= view_pos.w;
	vec3 world_scene = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
	float t_scene = distance(world_scene, CAMERA_POSITION_WORLD);
	t1 = min(t1, t_scene);

	if (t1 <= t0) {
		discard;
	}

	float ds = (t1 - t0) / float(steps);
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))) + TIME * 0.61);
	float t = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	vec3 sun_xz = normalize(vec3(sun_dir.x, 0.0, sun_dir.z));

	for (int i = 0; i < steps; i++) {
		if (t > t1) {
			break;
		}
		vec3 p = cam_obj + ray_dir * t;
		vec3 wp = p + model_origin;

		// Empty-space skip outside the wall and above the skirt band.
		vec3 cs = tw_centerline(wp.y);
		float rcs = tw_core_radius(wp.y);
		float rr = length(wp.xz - cs.xz);
		bool above_skirt = wp.y > 0.28 * funnel_height;
		if ((above_skirt && rr > 1.6 * rcs)
				|| (!above_skirt && rr > (3.2 + 1.2 * skirt_density) * r_core0)
				|| wp.y > funnel_height) {
			t += ds * 2.0;
			continue;
		}

		float skirt_w;
		float turb;
		float dens = funnel_density(wp, skirt_w, turb);
		if (dens > 0.003) {
			// Specials read lighter/denser: water and plasma are translucent media.
			float sigma_mul = storm_type == 1 ? 1.35 : (storm_type == 2 ? 0.75 : (storm_type == 3 ? 0.8 : (storm_type == 4 ? 0.65 : 1.0)));
			// Skirt medium is thinner than the wall: flying debris must silhouette through it.
			float sk_pre = clamp(skirt_w / max(dens, 1e-3), 0.0, 1.0);
			sigma_mul *= mix(1.0, 0.5, sk_pre);
			float sigma = dens * absorption * 0.02 * sigma_mul;
			// Sun-side brightness + vertical darkening toward the cloud base.
			vec2 rd2 = normalize(wp.xz - cs.xz);
			float sun_face = 0.45 + 0.55 * dot(vec3(rd2.x, 0.0, rd2.y), sun_xz);
			float y01 = wp.y / funnel_height;
			float vert = mix(1.0, 0.32, clamp(pow(y01, 0.7) * darkness * 1.6, 0.0, 1.0));
			float skirt_ratio = sk_pre;
			vec3 alb = mix(funnel_color, dust_color, skirt_ratio);
			float heat = clamp(turb - 0.4, 0.0, 1.2);
			vec3 scat;
			if (storm_type == 1) {
				// Fire whirl: blackbody by "heat" = turbulence, hotter at the base;
				// the skirt is a burning ground pool.
				float fheat = clamp(heat + skirt_ratio * 0.12, 0.0, 0.8);
				float t_k = 600.0 + 1250.0 * (1.0 - 0.7 * y01) * fheat;
				scat = fire_ramp(t_k) * (0.08 + 0.85 * heat * heat * (1.0 - 0.5 * y01) + 0.08 * skirt_ratio)
					+ alb * sun_face * vert * 0.25;
			} else if (storm_type == 2) {
				// Waterspout: dark sea core, turbulent streaks whipped into foam;
				// the skirt is a churning foam wall.
				float foam = smoothstep(0.95, 1.35, turb);
				foam = max(foam, skirt_ratio * smoothstep(0.55, 1.2, turb) * 0.9);
				scat = alb * sun_face * vert;
				scat = mix(scat, vec3(0.8, 0.88, 0.94) * sun_face, foam * 0.8);
			} else if (storm_type == 3) {
				// Ice: translucent crystal scatters light — soft directional shading,
				// ambient floor so the shadow side stays icy blue, sparse glints.
				// The skirt is a bright snow blast.
				float sun_ice = 0.7 + 0.3 * dot(vec3(rd2.x, 0.0, rd2.y), sun_xz);
				scat = alb * (0.5 + 0.45 * turb) * sun_ice * mix(1.0, 0.75, y01 * darkness)
					+ alb * (0.15 + 0.2 * skirt_ratio);
				scat += vec3(0.9, 0.97, 1.0) * sparkle_spin(wp, cs, rcs) * 2.0
					* (0.5 + 0.5 * sun_ice) * (1.0 + 0.6 * skirt_ratio);
			} else if (storm_type == 4) {
				// Plasma: dark body, emissive filaments, star glints;
				// the skirt is a crackling energy pool.
				float fil = smoothstep(1.0, 1.3, turb)
					+ skirt_ratio * 0.28 * smoothstep(0.7, 1.1, turb);
				vec3 ftint = mix(vec3(0.95, 0.3, 1.0), vec3(0.3, 0.8, 1.0), smoothstep(0.6, 1.4, turb + y01));
				scat = alb * vert * 0.45;
				scat += ftint * fil * 2.6;
				scat += vec3(1.0) * sparkle_spin(wp, cs, rcs) * 3.0;
			} else {
				scat = alb * sun_face * vert;
			}
			// User glow slider: extra self-emission, turbulence-modulated.
			scat += funnel_color * glow_amount * 1.8 * (1.0 - 0.7 * y01) * heat;

			// Interior lightning glow.
			vec3 dfl = wp - flash_pos;
			scat += flash_color * flash_intensity * exp(-dot(dfl, dfl) / (flash_radius * flash_radius));

			float absorb = exp(-sigma * ds);
			col += trans * scat * (1.0 - absorb);
			trans *= absorb;
			if (trans < 0.01) {
				break;
			}
		}
		t += ds;
	}

	float alpha = 1.0 - trans;
	ALBEDO = col / max(alpha, 1e-4);
	ALPHA = alpha;
}
