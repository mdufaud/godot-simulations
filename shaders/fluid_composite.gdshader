// Fullscreen composite for screen-space fluid: reconstructs view-space normals
// from the filtered depth, then shades water with Schlick fresnel, screen-space
// refraction and Beer-Lambert absorption over the accumulated thickness.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
uniform sampler2D fluid_depth_tex : filter_nearest;
uniform sampler2D thickness_tex : filter_linear;

uniform vec3 absorption = vec3(0.55, 0.18, 0.09);
uniform float absorption_scale = 0.5;
uniform vec3 tint_color : source_color = vec3(0.05, 0.32, 0.42);
uniform vec3 sky_color : source_color = vec3(0.55, 0.7, 0.85);
uniform vec3 sun_direction = vec3(0.5, -0.45, 0.7);
uniform float refraction_strength = 0.08;
uniform float spec_power = 180.0;
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

void fragment() {
	float fd = fluid_depth(SCREEN_UV);
	if (fd <= 0.001) {
		discard;
	}
	if (scene_eye_depth(SCREEN_UV, INV_PROJECTION_MATRIX, DEPTH_TEXTURE) < fd) {
		discard;
	}

	// View-space normal from filtered depth; pick the smaller one-sided
	// difference on each axis so silhouette edges don't smear normals
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

	vec3 v = -normalize(pc);
	float ndv = clamp(dot(n, v), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

	vec2 thick_rg = texture(thickness_tex, SCREEN_UV).rg;
	float thickness = thick_rg.r;
	vec3 sun_view = normalize((VIEW_MATRIX * vec4(-normalize(sun_direction), 0.0)).xyz);

	if (mode > 0.5) {
		// Shade from the FRONT surface temperature (filtered depth B channel);
		// mean-through-volume hides the cooled crust behind hot interior
		float t_surf = texture(fluid_depth_tex, SCREEN_UV).b;
		float t_mean = thick_rg.g / max(thickness, 1e-4);
		float diff = max(dot(n, sun_view), 0.0);
		vec3 crust_col = vec3(0.045, 0.04, 0.038) * (0.25 + 0.75 * diff);
		vec3 emis = lava_emission(t_surf);
		// Hot interior bleeding through a thin cooled crust
		emis += vec3(0.5, 0.07, 0.006) * smoothstep(0.35, 0.9, t_mean)
				* (1.0 - smoothstep(0.08, 0.35, t_surf));
		float glow = smoothstep(0.06, 0.32, t_surf);
		ALBEDO = mix(crust_col, emis, glow);
		ALPHA = clamp(thickness * 12.0, 0.0, 1.0);
	} else {
		vec2 refr_uv = SCREEN_UV - n.xy * refraction_strength * clamp(thickness, 0.0, 2.0);
		refr_uv = clamp(refr_uv, vec2(0.001), vec2(0.999));
		// Refracted sample in front of the fluid: fall back to unrefracted
		if (scene_eye_depth(refr_uv, INV_PROJECTION_MATRIX, DEPTH_TEXTURE) < fd) {
			refr_uv = SCREEN_UV;
		}
		vec3 scene_col = textureLod(SCREEN_TEXTURE, refr_uv, 0.0).rgb;
		vec3 trans = exp(-absorption * thickness * absorption_scale);
		vec3 refr_col = scene_col * trans + tint_color * (1.0 - trans);

		vec3 half_v = normalize(v + sun_view);
		float spec = pow(max(dot(n, half_v), 0.0), spec_power);

		ALBEDO = mix(refr_col, sky_color, fresnel) + vec3(spec);
		ALPHA = clamp(thickness * 8.0, 0.0, 1.0);
	}
}
