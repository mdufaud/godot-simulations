// Fullscreen composite for screen-space fluid. Reconstructs view-space normals
// from the filtered depth, then shades water with the FULL dielectric Fresnel
// equations (IOR 1->1.33, incl. total internal reflection), a Snell refraction
// offset, Beer-Lambert absorption, and a reflected-sky/sun highlight (SebLague
// technique). The lava branch shades from blackbody temperature.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
uniform sampler2D fluid_depth_tex : filter_nearest;
uniform sampler2D thickness_tex : filter_linear;
// White-particle prepass: R = coverage, G = linear eye depth of the sprite.
uniform sampler2D foam_tex : filter_linear;

uniform vec3 absorption = vec3(0.55, 0.18, 0.09);
uniform float absorption_scale = 0.5;
uniform vec3 tint_color : source_color = vec3(0.05, 0.32, 0.42);
uniform vec3 sky_zenith : source_color = vec3(0.16, 0.42, 0.75);
uniform vec3 sky_horizon : source_color = vec3(0.7, 0.8, 0.92);
uniform vec3 sun_direction = vec3(0.5, -0.45, 0.7);
uniform float sun_sharpness = 500.0;
uniform float sun_intensity = 12.0;
uniform float refraction_strength = 0.35;
uniform float ior = 1.33;
uniform float mode = 0.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

vec3 eye_pos_from_depth(vec2 uv, float eye_z, mat4 inv_proj) {
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 ray = p.xyz / p.w;
	return ray * (eye_z / -ray.z);
}

float scene_eye_depth(vec2 uv, mat4 inv_proj, sampler2D depth_sampler) {
	float raw = texture(depth_sampler, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

// Fluid depth packed R = floor(d), G = fract(d) against 16F quantization
float fluid_depth(vec2 uv) {
	vec2 rg = texture(fluid_depth_tex, uv).rg;
	return rg.x + rg.y;
}

// Blackbody-ish ramp: crust -> dull red -> orange -> yellow-white (HDR for glow)
vec3 lava_emission(float t) {
	vec3 c = mix(vec3(0.02, 0.008, 0.006), vec3(0.35, 0.03, 0.008), smoothstep(0.05, 0.3, t));
	c = mix(c, vec3(1.4, 0.28, 0.02), smoothstep(0.3, 0.65, t));
	c = mix(c, vec3(3.0, 1.5, 0.3), smoothstep(0.65, 0.95, t));
	return c;
}

// Full dielectric Fresnel (unpolarized average). in_dir points into the surface.
float dielectric_reflectance(vec3 in_dir, vec3 n, float ior_a, float ior_b) {
	float ratio = ior_a / ior_b;
	float cos_in = -dot(in_dir, n);
	float sin2_t = ratio * ratio * (1.0 - cos_in * cos_in);
	if (sin2_t >= 1.0) {
		return 1.0; // total internal reflection
	}
	float cos_t = sqrt(1.0 - sin2_t);
	float r_perp = (ior_a * cos_in - ior_b * cos_t) / (ior_a * cos_in + ior_b * cos_t);
	float r_par = (ior_b * cos_in - ior_a * cos_t) / (ior_b * cos_in + ior_a * cos_t);
	return (r_perp * r_perp + r_par * r_par) * 0.5;
}

vec3 snell_refract(vec3 in_dir, vec3 n, float ior_a, float ior_b) {
	float ratio = ior_a / ior_b;
	float cos_in = -dot(in_dir, n);
	float sin2_t = ratio * ratio * (1.0 - cos_in * cos_in);
	return ratio * in_dir + (ratio * cos_in - sqrt(max(1.0 - sin2_t, 0.0))) * n;
}

// world_dir sampled from an analytic sky gradient plus a sun disc.
vec3 sample_sky(vec3 world_dir, vec3 to_sun) {
	float t = clamp(world_dir.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 sky = mix(sky_horizon, sky_zenith, t);
	float sun = pow(max(dot(world_dir, to_sun), 0.0), sun_sharpness) * sun_intensity;
	return sky + vec3(sun);
}

void fragment() {
	float scene_d = scene_eye_depth(SCREEN_UV, INV_PROJECTION_MATRIX, DEPTH_TEXTURE);
	vec2 fm = texture(foam_tex, SCREEN_UV).rg;
	float foam = fm.r;
	float foam_d = fm.g;
	// Foam behind opaque scene geometry is hidden by it.
	if (foam_d > scene_d) {
		foam = 0.0;
	}

	float fd = fluid_depth(SCREEN_UV);
	// No fluid surface here (or scene geometry occludes it): airborne spray
	// still shows as white over whatever is behind it.
	if (fd <= 0.001 || scene_d < fd) {
		if (foam <= 0.002) {
			discard;
		}
		ALBEDO = vec3(1.0);
		ALPHA = foam;
	} else {

		// View-space normal from filtered depth; pick the smaller one-sided
		// difference on each axis so silhouette edges don't smear normals.
		vec2 ts = 1.0 / vec2(textureSize(fluid_depth_tex, 0));
		vec3 pc = eye_pos_from_depth(SCREEN_UV, fd, INV_PROJECTION_MATRIX);
		float dr = fluid_depth(SCREEN_UV + vec2(ts.x, 0.0));
		float dl = fluid_depth(SCREEN_UV - vec2(ts.x, 0.0));
		float du = fluid_depth(SCREEN_UV + vec2(0.0, ts.y));
		float dd = fluid_depth(SCREEN_UV - vec2(0.0, ts.y));
		vec3 ddx_v = eye_pos_from_depth(SCREEN_UV + vec2(ts.x, 0.0), dr, INV_PROJECTION_MATRIX) - pc;
		if (dl > 0.001 && (abs(dl - fd) < abs(dr - fd) || dr <= 0.001)) {
			ddx_v = pc - eye_pos_from_depth(SCREEN_UV - vec2(ts.x, 0.0), dl, INV_PROJECTION_MATRIX);
		}
		vec3 ddy_v = eye_pos_from_depth(SCREEN_UV + vec2(0.0, ts.y), du, INV_PROJECTION_MATRIX) - pc;
		if (dd > 0.001 && (abs(dd - fd) < abs(du - fd) || du <= 0.001)) {
			ddy_v = pc - eye_pos_from_depth(SCREEN_UV - vec2(0.0, ts.y), dd, INV_PROJECTION_MATRIX);
		}
		vec3 n = normalize(cross(ddy_v, ddx_v));
		if (n.z < 0.0) {
			n = -n;
		}

		vec2 thick_rg = texture(thickness_tex, SCREEN_UV).rg;
		float thickness = thick_rg.r;

		if (mode > 0.5) {
			// --- LAVA (preserved verbatim) ---
			vec3 sun_view = normalize((VIEW_MATRIX * vec4(-normalize(sun_direction), 0.0)).xyz);
			float t_surf = texture(fluid_depth_tex, SCREEN_UV).b;
			float t_mean = thick_rg.g / max(thickness, 1e-4);
			float diff = max(dot(n, sun_view), 0.0);
			vec3 crust_col = vec3(0.045, 0.04, 0.038) * (0.25 + 0.75 * diff);
			vec3 emis = lava_emission(t_surf);
			emis += vec3(0.5, 0.07, 0.006) * smoothstep(0.35, 0.9, t_mean)
					* (1.0 - smoothstep(0.08, 0.35, t_surf));
			float glow = smoothstep(0.06, 0.32, t_surf);
			ALBEDO = mix(crust_col, emis, glow);
			ALPHA = clamp(thickness * 12.0, 0.0, 1.0);
		} else {
			// --- WATER (SebLague-style dielectric surface) ---
			vec3 in_view = normalize(pc); // camera -> surface, view space
			float reflectance = dielectric_reflectance(in_view, n, 1.0, ior);

			// Snell-bent refraction: offset the screen sample by the lateral bend,
			// scaled by optical thickness; fall back if the sample is in front.
			vec3 rdir = snell_refract(in_view, n, 1.0, ior);
			vec2 refr_uv = SCREEN_UV + (rdir.xy - in_view.xy) * refraction_strength * clamp(thickness, 0.0, 2.0);
			refr_uv = clamp(refr_uv, vec2(0.001), vec2(0.999));
			if (scene_eye_depth(refr_uv, INV_PROJECTION_MATRIX, DEPTH_TEXTURE) < fd) {
				refr_uv = SCREEN_UV;
			}
			vec3 scene_col = textureLod(SCREEN_TEXTURE, refr_uv, 0.0).rgb;
			vec3 trans = exp(-absorption * thickness * absorption_scale);
			vec3 refr_col = scene_col * trans + tint_color * (1.0 - trans);

			// Reflection samples the sky + sun disc (the clean glassy glint).
			vec3 refl_view = reflect(in_view, n);
			vec3 refl_world = normalize((INV_VIEW_MATRIX * vec4(refl_view, 0.0)).xyz);
			vec3 to_sun = normalize(-sun_direction);
			vec3 refl_col = sample_sky(refl_world, to_sun);

			// Foam is opaque white coverage (SebLague): submerged froth tints what
			// is seen through the water, foam in front of the surface also takes
			// over the reflection.
			refr_col = refr_col * (1.0 - foam) + foam;
			if (foam_d < fd) {
				refl_col = refl_col * (1.0 - foam) + foam;
			}

			ALBEDO = mix(refr_col, refl_col, reflectance);
			ALPHA = max(clamp(thickness * 8.0, 0.0, 1.0), foam);
		}
	}
}
