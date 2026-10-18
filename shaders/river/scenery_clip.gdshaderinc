#include "res://shaders/river/river_swe.gdshaderinc"
uniform vec4 river_plane = vec4(0.0, 1.0, 0.0, 0.0);
uniform uint river_reflection_layer = uint(0);
uniform sampler2D river_height_texture : filter_linear, repeat_disable;
uniform vec2 river_domain_m = vec2(1.0);
uniform vec2 river_domain_origin_m = vec2(0.0);
uniform bool river_waterfall = false;
uniform vec2 river_pool_levels_m = vec2(0.0, 6.0);
uniform vec4 river_fall_geometry = vec4(6.0, 6.0, 4.0, 0.0);
uniform float river_fall_speed = 0.85;
uniform float river_fall_foam = 0.65;
uniform sampler2D waterfall_surface : filter_nearest, repeat_disable;

float river_cliff_wetness(vec3 position, float wet) {
	if (river_waterfall && river_fall_geometry.w > 0.0 && abs(position.x) < river_fall_geometry.x * 0.5
		&& position.z < river_fall_geometry.z && position.z > river_fall_geometry.z - river_fall_geometry.w) {
		vec2 uv = vec2(position.x / river_fall_geometry.x + 0.5,
			(river_fall_geometry.z - position.z) / river_fall_geometry.w);
		float depth = waterfall_clock_enabled ? max(textureLod(waterfall_surface, uv, 0.0).w,
			textureLod(swe_surface, river_swe_uv(position.xz), 0.0).w)
			: step(0.001, river_fall_speed) * dot(textureLod(river_height_texture,
				(vec2(position.x, river_fall_geometry.z + 0.3) - river_domain_origin_m) / river_domain_m + 0.5, 0.0).rg, vec2(-1.0, 1.0));
		return smoothstep(0.0001, 0.01, depth);
	}
	if (river_waterfall && river_fall_geometry.w == 0.0 && abs(position.z - river_fall_geometry.z) < 0.3) {
		float lateral = 1.0 - smoothstep(river_fall_geometry.x * 0.35, river_fall_geometry.x * 0.55, abs(position.x));
		float spray = exp(-max(position.y - river_pool_levels_m.x, 0.0) * 1.5) * river_fall_foam;
		float flowing = clamp(river_fall_speed, 0.0, 1.0) * (0.12 + spray);
		if (waterfall_clock_enabled) {
			vec4 clock = textureLod(waterfall_clock, vec2(0.5), 0.0);
			float age = sqrt(2.0 * max(river_pool_levels_m.y - position.y, 0.0) / 9.81);
			float row = mod(clock.g - floor(age * 120.0) + 256.0, 256.0);
			vec2 uv = vec2(clamp(position.x / river_fall_geometry.x + 0.5, 0.0, 1.0), (row + 0.5) / 256.0);
			vec4 sheet = textureLod(waterfall_surface, uv, 0.0);
			float contact = step(0.00001, sheet.w) * (1.0 - smoothstep(sheet.w, sheet.w + 0.15, abs(position.z - sheet.z)));
			float foam = textureLod(swe_foam, river_swe_uv(vec2(position.x, sheet.z)), 0.0).b;
			flowing = contact * 0.8 + foam * spray;
		}
		return clamp(lateral * flowing + (1.0 - smoothstep(0.0, 0.3, position.y - river_pool_levels_m.x)), 0.0, 1.0);
	}
	return wet;
}

float river_surface_height(vec3 position) {
	vec2 heights = texture(river_height_texture, (position.xz - river_domain_origin_m) / river_domain_m + 0.5).rg;
	float reference = heights.g;
	if (river_waterfall && river_fall_geometry.w > 0.0 && abs(position.x) < river_fall_geometry.x * 0.5
		&& position.z < river_fall_geometry.z && position.z > river_fall_geometry.z - river_fall_geometry.w) {
		vec2 uv = vec2(position.x / river_fall_geometry.x + 0.5,
			(river_fall_geometry.z - position.z) / river_fall_geometry.w);
		float cosine = cos(atan(river_fall_geometry.y / river_fall_geometry.w));
		if (waterfall_clock_enabled) {
			vec4 film = textureLod(waterfall_surface, uv, 0.0);
			if (film.w > 0.0001) { return film.y + film.w * cosine; }
			vec4 pool = textureLod(swe_surface, river_swe_uv(position.xz), 0.0);
			return pool.w > 0.004 ? pool.z : heights.r;
		}
		float speed = sqrt(river_fall_speed * river_fall_speed + 19.62 * uv.y * river_fall_geometry.y);
		return heights.r + (0.64 + river_pool_levels_m.x) * river_fall_speed / max(speed, 0.05) * cosine;
	}
	if (river_waterfall && texture(swe_surface, river_swe_uv(position.xz)).w < 0.004) { return reference; }
	return river_swe_height(position.xz, reference);
}

bool river_reflection_clipped(vec3 position, uint camera_layers) {
	if (river_waterfall) {
		if ((camera_layers & river_reflection_layer) != uint(0)) { return position.y < river_pool_levels_m.x; }
		if ((camera_layers & (river_reflection_layer << uint(1))) != uint(0)) { return position.y < river_pool_levels_m.y; }
		return false;
	}
	return (camera_layers & river_reflection_layer) != uint(0)
		&& position.y < river_surface_height(position);
}
