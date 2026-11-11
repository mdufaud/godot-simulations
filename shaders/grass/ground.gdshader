shader_type spatial;

#include "res://shaders/grass/wind_field.gdshaderinc"
#include "res://shaders/scenery/far_mountains.gdshaderinc"

uniform sampler2D cloud_shadow_texture : hint_default_white, filter_linear, repeat_disable;
uniform vec2 cloud_shadow_center = vec2(0.0);
uniform float cloud_shadow_extent = 256.0;

// Visual soil under the grass. Displaces the plane with the same heightmap
// sampling the blade shader uses (world xz over the texture size), so the
// ground, the grass and the HeightMapShape3D collision all follow one field.
uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float heightmap_scale = 5.0;
uniform sampler2D clump_noise : filter_linear, repeat_enable;
uniform vec3 moss_color : source_color = vec3(0.11, 0.19, 0.08);
uniform vec3 straw_color : source_color = vec3(0.32, 0.28, 0.13);
uniform vec3 distant_color : source_color = vec3(0.46, 0.52, 0.24);
uniform float chromatic_strength : hint_range(0.0, 1.0) = 0.0;
// Metres from the camera where the blades thin out and the soil takes their color.
uniform vec2 grass_cover_m = vec2(55.0, 95.0);

group_uniforms Backdrop;
// Far relief, off by default: the field is flat-plus-heightmap near the origin
// and only swells and rises into mountains far outside the grass tiles.
uniform float plain_swell_m = 0.0;
uniform float mountain_height_m = 0.0;
uniform vec2 mountain_range_m = vec2(1500.0, 5500.0);
uniform vec3 rock_color : source_color = vec3(0.3, 0.28, 0.27);
uniform vec3 snow_color : source_color = vec3(0.9, 0.93, 0.97);

varying vec3 ground_world;

float terrain_height(vec2 world_xz) {
	vec2 tex_size = vec2(textureSize(heightmap, 0));
	float radius = length(world_xz);
	// The tiling hillocks flatten outside the field, where the swell takes over.
	float height = (textureLod(heightmap, world_xz / tex_size, 0.0).r - 0.5) * heightmap_scale
		* mix(1.0, 0.3, smoothstep(160.0, 700.0, radius) * step(0.001, plain_swell_m));
	height += (textureLod(heightmap, world_xz / 3300.0 + vec2(0.31, 0.74), 0.0).r - 0.5)
		* plain_swell_m * smoothstep(140.0, 900.0, radius);
	height += far_mountain_height(heightmap, world_xz, mountain_range_m, mountain_height_m);
	return height;
}

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height = terrain_height(world_position.xz);
	world_position.y += height;
	VERTEX.y += height;
	ground_world = world_position;
}

void fragment() {
	vec2 world_xz = ground_world.xz;
	float camera_distance = distance(CAMERA_POSITION_WORLD.xz, world_xz);
	// Central differences per pixel: the far rings are too coarse for vertex normals.
	float eps = max(1.0, camera_distance * 0.006);
	float h = terrain_height(world_xz);
	float hx = terrain_height(world_xz + vec2(eps, 0.0));
	float hz = terrain_height(world_xz + vec2(0.0, eps));
	vec3 world_normal = normalize(vec3(h - hx, eps, h - hz));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	float broad = texture(clump_noise, world_xz * 0.012).r;
	float fine = texture(clump_noise, world_xz * 0.075).r;
	float ground_variation = textureLod(heightmap,
		world_xz / vec2(textureSize(heightmap, 0)), 0.0).r;
	float straw = clamp(0.3 + broad * 0.45 + fine * 0.15, 0.0, 1.0);
	ALBEDO = mix(moss_color, straw_color, straw)
		* mix(0.92, 1.08, smoothstep(0.2, 0.8, ground_variation));
	// Past the blades the soil stands in for the canopy: same tint, patchy at
	// pasture scale, and the same gusts racing over it as pale sheen.
	float distant_cover = smoothstep(grass_cover_m.x, grass_cover_m.y, camera_distance);
	float pasture = texture(clump_noise, world_xz * 0.0011).r;
	float patches = texture(clump_noise, world_xz * 0.0063).r;
	vec3 canopy = distant_color * mix(0.66, 0.92, pasture) * mix(0.9, 1.08, patches);
	canopy = mix(canopy, mix(moss_color, straw_color, 0.7) * 1.5, smoothstep(0.55, 0.8, pasture) * 0.35);
	float sheen = smoothstep(0.2, 0.9, wind_field(world_xz).z);
	canopy *= 1.0 + 0.3 * sheen * (1.0 - smoothstep(600.0, 2500.0, camera_distance));
	ALBEDO = mix(ALBEDO, canopy, distant_cover);

	float altitude = ground_world.y - plain_swell_m * 0.5;
	float steepness = 1.0 - world_normal.y;
	float rise = smoothstep(mountain_range_m.x, mountain_range_m.y, length(world_xz));
	float rock = smoothstep(60.0, 330.0, altitude + steepness * 500.0)
		* smoothstep(0.0, 0.08, rise) * step(0.001, mountain_height_m);
	vec3 scree = rock_color * mix(0.75, 1.2, patches) * mix(1.0, 0.7, smoothstep(0.2, 0.6, steepness));
	ALBEDO = mix(ALBEDO, scree, rock);
	float snow_line = mountain_height_m * (0.42 + 0.12 * (patches - 0.5));
	float snow = smoothstep(snow_line, snow_line * 1.25, altitude)
		* (1.0 - smoothstep(0.38, 0.62, steepness)) * step(0.001, mountain_height_m);
	ALBEDO = mix(ALBEDO, snow_color, snow);

	float chromatic_phase = world_xz.x * 0.013 + world_xz.y * 0.009;
	vec3 chromatic = 0.5 + 0.5 * cos(TAU * (chromatic_phase + vec3(0.0, 0.34, 0.68)));
	ALBEDO = mix(ALBEDO, chromatic * 0.22, chromatic_strength);
	ROUGHNESS = mix(0.95, 0.7, snow);
	// Grazing far slopes would otherwise mirror the pale horizon sky.
	SPECULAR = 0.04;
}

void light() {
	// The cloud map only covers the camera's surroundings; past its rim the
	// clamped edge would smear into rays, so the shadow fades out there.
	vec2 cloud_uv = (ground_world.xz - cloud_shadow_center) / cloud_shadow_extent + 0.5;
	vec2 rim = abs(cloud_uv - 0.5);
	float cloud_transmittance = mix(textureLod(cloud_shadow_texture, cloud_uv, 0.0).r, 1.0,
		smoothstep(0.4, 0.5, max(rim.x, rim.y)));
	float diffuse = clamp((dot(NORMAL, LIGHT) + 0.25) / 1.25, 0.0, 1.0);
	DIFFUSE_LIGHT += diffuse * LIGHT_COLOR
		* ATTENUATION * cloud_transmittance / PI;
}
