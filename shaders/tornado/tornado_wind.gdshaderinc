// Analytical tornado wind field — GLSL mirror of scripts/tornado/tornado_wind_field.gd.
// Keep the math in sync with wind_at(); the CPU side is the reference.

uniform int wind_model = 1; // 0 Vatistas n=1, 1 Burgers-Rott, 2 Sullivan
uniform float u_max = 85.0;
uniform float r_core0 = 45.0;
uniform float funnel_height = 550.0;
uniform float flare = 2.5;
uniform float a_bar = 0.15;
uniform float swirl_sign = 1.0;
uniform vec3 centerline[8];
uniform sampler2D sullivan_curve : filter_linear, repeat_disable;

// Peak of (1-exp(-a*r^2))/r at a*r^2 = root of (2x+1)*e^-x = 1: u_max at r_bar = 1.
const float TW_BR_ALPHA = 1.2564312;
const float TW_BR_NORM = 1.3979525;
const float TW_SULLIVAN_B = 3.0;
// Sullivan tangential peak sits 2.4976 viscous core radii out; the baked curve is
// rescaled by it, and the Sullivan v_r/v_z terms use it below (r_core = RMW).
const float TW_SULLIVAN_RMW = 2.4976;
const float TW_INFLOW_PEAK_R = 1.5;
const float TW_INFLOW_ONSET = 5.3;
const float TW_UPDRAFT_DEPTH = 3.0;
const float TW_TOP_CLOSE_START = 0.6;
const float TW_OUTER_TAPER_R = 6.0;
const float TW_INFLUENCE = 8.0;

float tw_core_radius(float y) {
	return r_core0 * (1.0 + flare * pow(clamp(y / funnel_height, 0.0, 1.0), 1.5));
}

float tw_core_radius_slope(float y) {
	if (y <= 0.0 || y >= funnel_height) {
		return 0.0;
	}
	return r_core0 * flare * 1.5 * sqrt(y / funnel_height) / funnel_height;
}

// World-space vortex axis position at height y (slice lerp).
vec3 tw_centerline(float y) {
	float t = clamp(y / funnel_height, 0.0, 1.0) * 7.0;
	int i = int(min(t, 6.0));
	return mix(centerline[i], centerline[i + 1], t - float(i));
}

// Normalized tangential profile (peak 1 at r_bar = 1, the RMW).
float tw_v_theta(float r_bar) {
	float r_safe = max(r_bar, 1e-3);
	if (wind_model == 0) {
		return 2.0 * r_bar / (1.0 + r_bar * r_bar);
	}
	if (wind_model == 1) {
		return TW_BR_NORM * (1.0 - exp(-TW_BR_ALPHA * r_bar * r_bar)) / r_safe;
	}
	// Texel centres hold r_bar = 8 i / 255 (TornadoWindField.build_sullivan_image).
	float u = clamp(r_bar / 8.0, 0.0, 1.0) * (255.0 / 256.0) + 0.5 / 256.0;
	return texture(sullivan_curve, vec2(u, 0.5)).r;
}

// (Phi/rho, Phi'/rho) of the active model (TornadoWindField._radial_shape).
vec2 tw_radial_shape(float r_bar) {
	float peak = wind_model == 0 ? 1.0 : TW_INFLOW_PEAK_R;
	float d = 1.0 + r_bar * r_bar / (peak * peak);
	vec2 shape = vec2(r_bar / d, 2.0 / (d * d));
	if (wind_model == 2) {
		float e = exp(-TW_SULLIVAN_RMW * TW_SULLIVAN_RMW * r_bar * r_bar);
		shape.x -= TW_SULLIVAN_B / (TW_SULLIVAN_RMW * TW_SULLIVAN_RMW) * (1.0 - e) / max(r_bar, 1e-6);
		shape.y -= 2.0 * TW_SULLIVAN_B * e;
	}
	return shape;
}

// (v_r, v_theta, v_z) / u_max (TornadoWindField.cylindrical_wind): v_r and v_z from
// the stream function, so the field is divergence-free.
vec3 tw_cylindrical(float r_bar, float y) {
	if (y < 0.0 || y > funnel_height || r_bar > TW_INFLUENCE) {
		return vec3(0.0);
	}
	float s = tw_core_radius(y);
	float ds = tw_core_radius_slope(y);
	float taper_t = clamp((r_bar - TW_OUTER_TAPER_R) / (TW_INFLUENCE - TW_OUTER_TAPER_R), 0.0, 1.0);
	float taper = 1.0 - taper_t * taper_t * (3.0 - 2.0 * taper_t);
	float dtaper = -6.0 * taper_t * (1.0 - taper_t) / (TW_INFLUENCE - TW_OUTER_TAPER_R);
	float rise = exp(-TW_INFLOW_ONSET * y / (TW_UPDRAFT_DEPTH * r_core0));
	float close_t = clamp((y - TW_TOP_CLOSE_START * funnel_height)
		/ ((1.0 - TW_TOP_CLOSE_START) * funnel_height), 0.0, 1.0);
	float close_v = 1.0 - close_t * close_t * (3.0 - 2.0 * close_t);
	float dclose = -6.0 * close_t * (1.0 - close_t) / ((1.0 - TW_TOP_CLOSE_START) * funnel_height);
	float level = TW_UPDRAFT_DEPTH * (1.0 - rise) * close_v;
	float dlevel = (TW_INFLOW_ONSET / r_core0) * rise * close_v
		+ TW_UPDRAFT_DEPTH * (1.0 - rise) * dclose;
	vec2 shape = tw_radial_shape(r_bar);
	float v_z = a_bar * level * (shape.y * taper + shape.x * dtaper);
	float v_r = -a_bar * (ds * level * (2.0 * taper * shape.x - r_bar * taper * shape.y
		- r_bar * shape.x * dtaper) + s * dlevel * taper * shape.x);
	float fade = (1.0 - smoothstep(0.85 * funnel_height, funnel_height, y)) * taper;
	return vec3(v_r, tw_v_theta(r_bar) * fade, v_z);
}

// Full wind velocity (m/s) at world position p. Ground is y = 0.
vec3 tw_wind(vec3 p) {
	if (p.y > funnel_height || p.y < 0.0) {
		return vec3(0.0);
	}
	vec3 c = tw_centerline(p.y);
	float r_core = tw_core_radius(p.y);
	vec2 rel = p.xz - c.xz;
	float r = length(rel);
	float r_bar = r / r_core;
	if (r_bar > TW_INFLUENCE) {
		return vec3(0.0);
	}
	vec3 w = tw_cylindrical(r_bar, p.y);
	vec3 r_dir = r > 1e-4 ? vec3(rel.x, 0.0, rel.y) / r : vec3(0.0);
	vec3 t_dir = swirl_sign * cross(vec3(0.0, 1.0, 0.0), r_dir);
	return (r_dir * w.x + t_dir * w.y + vec3(0.0, 1.0, 0.0) * w.z) * u_max;
}
