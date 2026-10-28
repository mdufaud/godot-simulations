#include "res://shaders/river/river_swe.gdshaderinc"
uniform vec4 river_plane = vec4(0.0, 1.0, 0.0, 0.0);
uniform uint river_reflection_layer = uint(0);
uniform sampler2D river_height_texture : filter_linear, repeat_disable;
uniform vec2 river_domain_m = vec2(1.0);
uniform vec2 river_domain_origin_m = vec2(0.0);
// Each reflection plane mirrors one pool, and its camera clips the scenery below that pool's level.
uniform bool river_pool_planes = false;
uniform vec2 river_pool_levels_m = vec2(0.0, 6.0);

// Highest level (x) and depth (y) of the water among the solver cells around a point, x far below when all are dry.
vec2 river_nearby_water(vec2 point) {
	ivec2 cell = river_swe_cell(point);
	ivec2 size = textureSize(swe_surface, 0);
	vec2 water = vec2(-1.0e6, 0.0);
	for (int k = 0; k < 9; k++) {
		vec4 state = texelFetch(swe_surface, clamp(cell + ivec2(k % 3 - 1, k / 3 - 1), ivec2(0), size - 1), 0);
		water = state.w > 0.004 ? max(water, state.zw) : water;
	}
	return water;
}

// Height above its waterline that water wets the ground: waves, and so their splashes, stay under 0.78 of the depth.
float river_wet_band(vec3 position) {
	if (!swe_spill_enabled) { return 0.35; }
	return clamp(0.78 * river_nearby_water(position.xz).y, 0.04, 0.35);
}

// Rock beside a spilling face is kept wet by the water pouring over it, below that water's level only.
float river_cliff_wetness(vec3 position, float wet) {
	if (river_spill_faces(position.xz) == 0) { return wet; }
	float pouring = river_nearby_water(position.xz).x;
	return max(wet, 0.8 * (1.0 - smoothstep(pouring, pouring + 0.1, position.y)));
}

float river_surface_height(vec3 position) {
	float reference = texture(river_height_texture, (position.xz - river_domain_origin_m) / river_domain_m + 0.5).g;
	if (swe_spill_enabled && texture(swe_surface, river_swe_uv(position.xz)).w < 0.004) { return reference; }
	return river_swe_height(position.xz, reference);
}

bool river_reflection_clipped(vec3 position, uint camera_layers) {
	if (river_pool_planes) {
		if ((camera_layers & river_reflection_layer) != uint(0)) { return position.y < river_pool_levels_m.x; }
		if ((camera_layers & (river_reflection_layer << uint(1))) != uint(0)) { return position.y < river_pool_levels_m.y; }
		return false;
	}
	return (camera_layers & river_reflection_layer) != uint(0)
		&& position.y < river_surface_height(position);
}
