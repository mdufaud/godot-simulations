shader_type spatial;
// Far ground ring around the tornado plain (grass_scenery.build_far_ground):
// the plain's own far tone, rising into the shared horizon range.
render_mode cull_back;

#include "res://shaders/scenery/far_mountains.gdshaderinc"

uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float mountain_height_m = 1500.0;
uniform vec2 mountain_range_m = vec2(3200.0, 11000.0);
// Mean ground tone of the look (tornado_ground.gdshader's far field).
uniform vec3 plain_color : source_color = vec3(0.23, 0.2, 0.17);
uniform vec3 rock_color : source_color = vec3(0.2, 0.19, 0.19);
uniform vec3 snow_color : source_color = vec3(0.8, 0.84, 0.9);
uniform float snow_amount : hint_range(0.0, 1.0) = 0.6;
// The ring hangs this far under the ground plane until it clears the plane's
// corners, so the two never fight for depth.
uniform float sink_m = 3.0;
uniform vec2 sink_range_m = vec2(4300.0, 5000.0);

varying vec3 v_world;

float relief(vec2 world_xz) {
	return far_mountain_height(heightmap, world_xz, mountain_range_m, mountain_height_m)
		- sink_m * (1.0 - smoothstep(sink_range_m.x, sink_range_m.y, length(world_xz)));
}

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height = relief(world_position.xz);
	VERTEX.y += height;
	world_position.y += height;
	v_world = world_position;
}

void fragment() {
	vec2 world_xz = v_world.xz;
	// Central differences per pixel: the far rings are too coarse for vertex normals.
	float eps = max(1.0, distance(CAMERA_POSITION_WORLD.xz, world_xz) * 0.006);
	float h = relief(world_xz);
	vec3 world_normal = normalize(vec3(h - relief(world_xz + vec2(eps, 0.0)), eps,
		h - relief(world_xz + vec2(0.0, eps))));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	float patches = textureLod(heightmap, world_xz / 1600.0, 0.0).r;
	float steepness = 1.0 - world_normal.y;
	// 0.55: the ground plane's own far darkening (tornado_ground.gdshader).
	vec3 albedo = plain_color * 0.55;
	float rock = smoothstep(60.0, 330.0, v_world.y + steepness * 500.0);
	albedo = mix(albedo, rock_color * mix(0.75, 1.2, patches)
		* mix(1.0, 0.7, smoothstep(0.2, 0.6, steepness)), rock);
	float snow_line = mountain_height_m * (0.42 + 0.12 * (patches - 0.5));
	float snow = smoothstep(snow_line, snow_line * 1.25, v_world.y)
		* (1.0 - smoothstep(0.38, 0.62, steepness)) * snow_amount;
	ALBEDO = mix(albedo, snow_color, snow);
	ROUGHNESS = mix(0.95, 0.7, snow);
	// Grazing far slopes would otherwise mirror the pale horizon band.
	SPECULAR = 0.04;
}
