// Horizon mountain range shared by the demo backdrops: ridged noise from a
// seamless heightmap, rising between two radii around the world origin.

float far_ridge(sampler2D heightmap, vec2 uv) {
	return 1.0 - abs(2.0 * textureLod(heightmap, uv, 0.0).r - 1.0);
}

// Height (m) of the range at world_xz: 0 inside range_m.x, full relief past range_m.y.
float far_mountain_height(sampler2D heightmap, vec2 world_xz, vec2 range_m, float height_m) {
	float rise = smoothstep(range_m.x, range_m.y, length(world_xz));
	if (rise <= 0.0 || height_m <= 0.0) {
		return 0.0;
	}
	float massif = textureLod(heightmap, world_xz / 90000.0 + vec2(0.37, 0.12), 0.0).r;
	float ridges = far_ridge(heightmap, world_xz / 52000.0) * 0.6
		+ far_ridge(heightmap, world_xz / 21000.0 + vec2(0.21, 0.67)) * 0.26
		+ far_ridge(heightmap, world_xz / 8300.0 + vec2(0.63, 0.05)) * 0.1
		+ far_ridge(heightmap, world_xz / 3100.0 + vec2(0.9, 0.44)) * 0.04;
	return rise * height_m * ridges * ridges * (0.25 + 0.75 * smoothstep(0.36, 0.6, massif));
}
