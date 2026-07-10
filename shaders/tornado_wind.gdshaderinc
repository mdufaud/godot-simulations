// Analytical tornado wind field — GLSL mirror of scripts/demos/tornado_wind_field.gd.
// Keep the math in sync with wind_at(); the CPU side is the reference.

uniform int wind_model = 1; // 0 Rankine, 1 Burgers-Rott, 2 Sullivan
uniform float u_max = 85.0;
uniform float r_core0 = 45.0;
uniform float funnel_height = 550.0;
uniform float flare = 2.5;
uniform float a_bar = 0.15;
uniform float swirl_sign = 1.0;
uniform vec3 centerline[8];
uniform sampler2D sullivan_curve : filter_linear, repeat_disable;

const float TW_BR_ALPHA = 1.256643;
const float TW_BR_NORM = 1.397948;
const float TW_SULLIVAN_B = 3.0;
const float TW_R_BAR_MAX = 4.0;
const float TW_Z_BAR_CAP = 6.0;
const float TW_INFLUENCE = 8.0;

float tw_core_radius(float y) {
	return r_core0 * (1.0 + flare * pow(clamp(y / funnel_height, 0.0, 1.0), 1.5));
}

// World-space vortex axis position at height y (slice lerp).
vec3 tw_centerline(float y) {
	float t = clamp(y / funnel_height, 0.0, 1.0) * 7.0;
	int i = int(min(t, 6.0));
	return mix(centerline[i], centerline[i + 1], t - float(i));
}

// Normalized tangential profile (peak 1 at r_bar ~ 1).
float tw_v_theta(float r_bar) {
	float r_safe = max(r_bar, 1e-3);
	if (wind_model == 0) {
		return 2.0 * r_bar / (1.0 + r_bar * r_bar);
	}
	if (wind_model == 1) {
		return TW_BR_NORM * (1.0 - exp(-TW_BR_ALPHA * r_bar * r_bar)) / r_safe;
	}
	return texture(sullivan_curve, vec2(r_bar / 8.0, 0.5)).r;
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
	float z_bar = min(p.y / r_core, TW_Z_BAR_CAP);
	float z_eff = TW_Z_BAR_CAP * (1.0 - exp(-0.8 * z_bar));
	float rb = min(r_bar, TW_R_BAR_MAX);
	float r_safe = max(r_bar, 1e-3);

	float v_t = tw_v_theta(r_bar);
	float v_r = 0.0;
	float v_z = 0.0;
	if (wind_model == 1) {
		v_r = -a_bar * rb;
		v_z = 2.0 * a_bar * z_eff * exp(-0.25 * r_bar * r_bar);
	} else if (wind_model == 2) {
		float e = exp(-r_bar * r_bar);
		v_r = a_bar * (-rb + (TW_SULLIVAN_B / r_safe) * (1.0 - e));
		v_z = 2.0 * a_bar * z_eff * (1.0 - TW_SULLIVAN_B * e) * exp(-0.15 * r_bar * r_bar);
	}
	if (wind_model != 0) {
		// Corner flow: near-ground annular updraft jet + intensified surface inflow.
		float dr = (r_bar - 1.0) / 0.45;
		v_z += 2.5 * a_bar * exp(-dr * dr) * (1.0 - exp(-8.0 * z_bar)) * exp(-0.5 * z_bar);
		v_r *= 1.0 + 0.75 * exp(-1.5 * z_bar);
	}

	v_z *= 1.0 - smoothstep(0.85 * funnel_height, funnel_height, p.y);
	float fade = 1.0 - smoothstep(6.0, 8.0, r_bar);
	v_t *= fade;
	v_r *= fade;
	v_z *= fade;

	vec3 r_dir = r > 1e-4 ? vec3(rel.x, 0.0, rel.y) / r : vec3(0.0);
	vec3 t_dir = swirl_sign * cross(vec3(0.0, 1.0, 0.0), r_dir);
	return (r_dir * v_r + t_dir * v_t + vec3(0.0, 1.0, 0.0) * v_z) * u_max;
}
