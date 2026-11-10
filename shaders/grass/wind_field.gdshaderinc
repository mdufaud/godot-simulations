// Canopy wind shared by the blades and the far ground sheen. Four noise layers
// in a wind-aligned frame (x streamwise, y crosswind), each advected at its own
// pace; the phases are accumulated and wrapped on the CPU in 64-bit.
uniform sampler2D wind_noise : filter_linear, repeat_enable;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform vec2 wind_direction = vec2(0.819, 0.574);
uniform float gustiness : hint_range(0.0, 1.0) = 0.65;
// Noise tile length per layer in metres: xy = gust (streamwise, crosswind),
// zw = wave front (streamwise, crosswind).
uniform vec4 wind_gust_wave_tile_m = vec4(1.0);
// x = eddy tile, y = veer tile, both isotropic.
uniform vec2 wind_eddy_veer_tile_m = vec2(1.0);
// Streamwise phase of gust, wave, eddy and veer layers, in noise tiles.
uniform vec4 wind_phase = vec4(0.0);
uniform float wind_veer_rad = 0.0;

// xy: local wind direction scaled by its strength (0 calm, ~1 full gust);
// z: strength alone; w: fine eddy in [-0.5, 0.5].
vec4 wind_field(vec2 world_xz) {
	vec2 mean_direction = normalize(wind_direction);
	vec2 crosswind = vec2(-mean_direction.y, mean_direction.x);
	vec2 frame = vec2(dot(world_xz, mean_direction), dot(world_xz, crosswind));
	vec2 veer_sample = textureLod(wind_noise, frame / wind_eddy_veer_tile_m.y
		- vec2(wind_phase.w, 0.0) + vec2(0.17, 0.59), 0.0).rg;
	float veer = textureLod(wind_noise, frame.yx / wind_eddy_veer_tile_m.y
		+ vec2(0.71, wind_phase.w * 0.6), 0.0).r - 0.5;
	// The veer noise also warps the faster layers so no front stays straight.
	vec2 warp = vec2(veer_sample.r - 0.5, veer) * 0.35;
	float gust_noise = textureLod(wind_noise, frame / wind_gust_wave_tile_m.xy
		- vec2(wind_phase.x, 0.0) + warp * 0.4, 0.0).r;
	float wave_noise = textureLod(wind_noise, frame / wind_gust_wave_tile_m.zw
		- vec2(wind_phase.y, 0.0) + warp + vec2(0.41, 0.23), 0.0).r;
	float eddy = textureLod(wind_noise, frame / wind_eddy_veer_tile_m.x
		- vec2(wind_phase.z, 0.0) + vec2(0.83, 0.11), 0.0).r - 0.5;
	// Gusts are intermittent: long lulls between sweeps, not a steady swell.
	float gust = smoothstep(0.4, 0.66, gust_noise);
	// Positive skew: short fast sweeps over a calmer background.
	float wave = smoothstep(0.3, 0.78, wave_noise);
	wave *= wave;
	float lull = mix(1.0, 0.22 + 0.98 * gust, gustiness);
	float strength = clamp(wind_speed / 5.0, 0.0, 1.0)
		* lull * mix(1.0, 0.4 + 1.1 * wave, 0.35 + 0.65 * gustiness);
	float angle = (veer * 2.0 * wind_veer_rad + (wave_noise - 0.5) * 0.6) * gustiness;
	float s = sin(angle);
	float c = cos(angle);
	vec2 local_direction = mean_direction * c + crosswind * s;
	return vec4(local_direction * strength, strength, eddy);
}
