// Storm cloud deck over the ocean: huge disc dished down toward the horizon
// (no sky band survives below the rim), FBM density gated by a 0-1 cover
// param, local lightning glow. Derived from tornado_cloud.gdshader minus the
// funnel coupling. Engine fog blends the dipping rim into the horizon.

shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform vec3 cloud_color : source_color = vec3(0.34, 0.36, 0.42);
uniform float cover : hint_range(0.0, 1.0) = 0.0;
uniform float deck_radius = 4200.0;
uniform float noise_scale : hint_range(0.0002, 0.01) = 0.0005;
uniform vec2 wind_drift = vec2(7.0, 2.5);
uniform float flash_intensity = 0.0;
uniform vec3 flash_pos = vec3(0.0, 300.0, 0.0);
uniform float flash_radius = 260.0;
uniform vec3 flash_color : source_color = vec3(0.8, 0.85, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Perspective dish: the deck bends down and under the horizon far away.
	float d = length(VERTEX.xz);
	VERTEX.y -= pow(d / 3800.0, 2.2) * 1000.0;
}

void fragment() {
	vec2 nuv = world_pos.xz + wind_drift * TIME;
	float n = texture(noise_tex, vec3(nuv * noise_scale, 0.21)).r;
	float n2 = texture(noise_tex, vec3(nuv * noise_scale * 2.7 + 40.0, 0.67 + TIME * 0.004)).r;
	float fbm = n * 0.7 + n2 * 0.3;

	float r = length(world_pos.xz);
	float deck = 1.0 - smoothstep(0.85, 1.0, (r + 300.0 * (n - 0.5)) / deck_radius);
	// Low cover keeps only the densest clumps; full cover closes the sky but
	// keeps FBM structure (never fully saturates to a flat sheet).
	float dens = deck * smoothstep(0.95 - cover * 0.85, 1.35 - cover * 0.75, fbm + 0.18 * cover);

	// Dense cores darken hard at full cover: black storm belly.
	vec3 col = cloud_color * mix(1.15, 0.22, clamp(fbm * (0.4 + 0.85 * cover), 0.0, 1.0));
	float fl = flash_intensity * exp(-distance(world_pos, flash_pos) / flash_radius);
	col += flash_color * fl;

	ALBEDO = col;
	ALPHA = clamp(dens, 0.0, 1.0);
}
