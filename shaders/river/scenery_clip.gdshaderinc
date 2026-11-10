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
		water = state.w > swe_wet_depth_m ? max(water, state.zw) : water;
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

// Albedo factor of wet rock and ground: a light film at the waterline, darker with the depth under the surface (height < 0).
float river_wet_darkening(float wet, float height) {
	return mix(1.0, mix(0.8, 0.6, smoothstep(0.0, 1.5, -height)), wet);
}

float river_reference_height(vec3 position) {
	return texture(river_height_texture, (position.xz - river_domain_origin_m) / river_domain_m + 0.5).g;
}

// The level of the water over a point, and whether that water shows. On a spilling field it is the surface the cell
// mesh draws (river_water.gdshader), shown where thicker than the film it fades out under; over a cell drawing no
// quad, the guided surface, which the mesh draws only outside the solver's blend. Under a film too thin to show, the
// level eases to that guided surface with the film's depth, so wet ground ends on the film's edge, not on a cell's.
float river_water_level(vec3 position, out bool shown) {
	float reference = river_reference_height(position);
	float weight = river_swe_weight(position.xz);
	shown = true;
	if (!swe_spill_enabled || weight <= 0.0) { return river_swe_height(position.xz, reference); }
	float drawn = river_drawn_level(position.xz);
	if (isinf(drawn)) {
		vec2 centre = swe_region_m.xy + (vec2(river_swe_cell(position.xz)) + 0.5) * swe_region_m.zw / vec2(textureSize(swe_corners, 0));
		shown = river_swe_weight(centre) <= 0.0;
		return reference;
	}
	float depth = texture(swe_surface, river_swe_uv(position.xz)).w;
	shown = depth > RIVER_FILM_DEPTH_M;
	return mix(reference, drawn, weight * smoothstep(0.0, RIVER_FILM_DEPTH_M, depth));
}

// The level of the water showing over a point; where none shows, never above the point, so ground under a faded film
// stands at the water, wet, and ground under none is above it.
float river_surface_height(vec3 position) {
	bool shown;
	float level = river_water_level(position, shown);
	return shown ? level : min(level, position.y);
}

// Height above the water that ground grows by: on a spilling field above the guided surface, whatever the live water
// does. A pocket left dry under it stays bare, and a flood over a bank wets its grass instead of stripping it by the cell.
float river_growth_height(vec3 position, float height) {
	return swe_spill_enabled ? position.y - river_reference_height(position) : height;
}

bool river_reflection_clipped(vec3 position, uint camera_layers) {
	if (river_pool_planes) {
		if ((camera_layers & river_reflection_layer) != uint(0)) { return position.y < river_pool_levels_m.x; }
		if ((camera_layers & (river_reflection_layer << uint(1))) != uint(0)) { return position.y < river_pool_levels_m.y; }
		return false;
	}
	bool shown;
	return (camera_layers & river_reflection_layer) != uint(0)
		&& position.y < river_water_level(position, shown);
}
