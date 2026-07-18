shader_type spatial;
// Storm cloud deck at the funnel top: huge disc dished down toward the horizon
// so the overcast fully encloses the scene, FBM shaded, differential rotation
// (fast collar above the funnel, near-static deck far out). Viewed from below —
// cull_disabled. Engine fog stays ON: it blends the dipping rim into the horizon.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

#include "res://shaders/tornado/tornado_wind.gdshaderinc"

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform vec3 cloud_color : source_color = vec3(0.36, 0.38, 0.44);
uniform vec3 dust_color : source_color = vec3(0.55, 0.42, 0.28);
uniform vec3 sun_dir = vec3(-0.5, 0.0, -0.6);
uniform float cloud_opacity : hint_range(0.0, 1.0) = 1.0;
uniform float deck_radius = 4200.0;
uniform float noise_scale : hint_range(0.0002, 0.01) = 0.0016;
uniform int storm_type = 0; // 0 normal, 1 fire, 2 water, 3 ice, 4 plasma
uniform float flash_intensity = 0.0;
uniform vec3 flash_pos = vec3(0.0, 200.0, 0.0);
uniform float flash_radius = 140.0;
uniform vec3 flash_color : source_color = vec3(0.8, 0.85, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Perspective dish: the deck bends down and under the horizon far away,
	// so no sky band survives below the cloud rim.
	float d = length(VERTEX.xz);
	VERTEX.y -= pow(d / 3800.0, 2.2) * 1000.0;
}

void fragment() {
	vec3 c = tw_centerline(funnel_height);
	vec2 rel = world_pos.xz - c.xz;
	float r = length(rel);
	float rc_top = tw_core_radius(funnel_height);

	// Differential rotation: collar spins with the funnel top, deck barely moves.
	// Polar swirl only near the collar — polar mapping far out stretches into
	// radial streaks, so the deck blends back to plain world coords + slow drift.
	float ang = atan(rel.y, rel.x);
	float spin = swirl_sign * (u_max / max(rc_top, 1.0)) * 0.3;
	float a = ang - TIME * spin / (1.0 + pow(r / max(2.0 * rc_top, 1.0), 1.6));
	vec2 nuv_polar = vec2(cos(a), sin(a)) * r;
	vec2 nuv_flat = rel + vec2(TIME * 4.0, TIME * 1.5);
	float polar_w = exp(-r / (4.0 * rc_top));
	vec2 nuv = mix(nuv_flat, nuv_polar, polar_w);

	float n = texture(noise_tex, vec3(nuv * noise_scale, 0.21)).r;
	float n2 = texture(noise_tex, vec3(nuv * noise_scale * 3.1 + 40.0, 0.67 + TIME * 0.004)).r;
	float fbm = n * 0.65 + n2 * 0.35;

	// Rotating collar (wall cloud) just above the funnel; ragged edge from noise.
	float collar = exp(-pow(r / (3.0 * rc_top), 2.0));
	// Stay opaque almost to the rim — the dish already hides the far edge
	// below the horizon; the fade only matters when the coverage slider shrinks.
	float deck = 1.0 - smoothstep(0.88, 1.0, (r + 300.0 * (n - 0.5)) / deck_radius);
	float dens = deck * (0.85 + 0.4 * fbm) + collar * 0.5;

	vec2 rd2 = r > 1e-3 ? rel / r : vec2(0.0);
	vec3 sun_xz = normalize(vec3(sun_dir.x, 0.0, sun_dir.z));
	float sun_face = 0.75 + 0.25 * dot(vec3(rd2.x, 0.0, rd2.y), sun_xz);

	// Deck mottled by noise; heavy dark zone graded toward the tornado so the
	// ceiling matches the funnel instead of floating light-gray above it.
	float darkzone = 1.0 - 0.5 * exp(-r / (6.0 * rc_top));
	vec3 col = cloud_color * (0.35 + 0.4 * fbm) * sun_face * darkzone;
	col = mix(col, cloud_color * 0.2 + dust_color * 0.1, collar * (0.6 + 0.3 * fbm));

	if (storm_type == 1) {
		// Fire underglow on the collar, flickering with the noise.
		col += vec3(1.0, 0.35, 0.05) * collar * (0.25 + 0.35 * fbm);
	} else if (storm_type == 4) {
		// Plasma veins crawling through the deck near the vortex.
		float veins = smoothstep(0.62, 0.75, n2);
		col += vec3(0.7, 0.25, 1.0) * collar * (0.3 + 0.55 * veins);
	}

	// Intra-cloud lightning glow.
	vec3 dfl = world_pos - flash_pos;
	col += flash_color * flash_intensity * 0.4
		* exp(-dot(dfl.xz, dfl.xz) / (4.0 * flash_radius * flash_radius));

	ALBEDO = col;
	ALPHA = clamp(dens, 0.0, 1.0) * cloud_opacity;
}
