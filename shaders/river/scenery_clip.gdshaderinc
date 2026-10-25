#include "res://shaders/river/river_swe.gdshaderinc"
uniform vec4 river_plane = vec4(0.0, 1.0, 0.0, 0.0);
uniform uint river_reflection_layer = uint(0);
uniform sampler2D river_height_texture : filter_linear, repeat_disable;
uniform vec2 river_domain_m = vec2(1.0);
uniform vec2 river_domain_origin_m = vec2(0.0);
// Each reflection plane mirrors one pool, and its camera clips the scenery below that pool's level.
uniform bool river_pool_planes = false;
uniform vec2 river_pool_levels_m = vec2(0.0, 6.0);

// Rock beside a spilling face is kept wet by the water pouring over it.
float river_cliff_wetness(vec3 position, float wet) {
	return river_spill_faces(position.xz) != 0 ? max(wet, 0.8) : wet;
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
