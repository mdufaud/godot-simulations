shader_type spatial;

// Visual soil under the grass. Displaces the plane with the same heightmap
// sampling the blade shader uses (world xz over the texture size), so the
// ground, the grass and the HeightMapShape3D collision all follow one field.
uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float heightmap_scale = 5.0;
uniform sampler2D clump_noise : filter_linear, repeat_enable;
uniform vec3 moss_color : source_color = vec3(0.11, 0.19, 0.08);
uniform vec3 straw_color : source_color = vec3(0.32, 0.28, 0.13);
uniform float chromatic_strength : hint_range(0.0, 1.0) = 0.0;
varying float ground_variation;
varying vec2 ground_world_xz;

float terrain_height(vec2 world_xz, vec2 tex_size) {
	return (texture(heightmap, world_xz / tex_size).x - 0.5) * heightmap_scale;
}

void vertex() {
	vec2 tex_size = vec2(textureSize(heightmap, 0));
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 world_xz = world_position.xz;
	ground_world_xz = world_xz;
	VERTEX.y += terrain_height(world_xz, tex_size);
	ground_variation = texture(heightmap, world_xz / tex_size).r;
	// Central differences: a displaced plane keeps flat normals otherwise.
	float eps = 1.0;
	float h = terrain_height(world_xz, tex_size);
	float hx = terrain_height(world_xz + vec2(eps, 0.0), tex_size);
	float hz = terrain_height(world_xz + vec2(0.0, eps), tex_size);
	NORMAL = normalize(vec3(h - hx, eps, h - hz));
}

void fragment() {
	float broad = texture(clump_noise, ground_world_xz * 0.012).r;
	float fine = texture(clump_noise, ground_world_xz * 0.075).r;
	float straw = clamp(0.3 + broad * 0.45 + fine * 0.15, 0.0, 1.0);
	ALBEDO = mix(moss_color, straw_color, straw)
		* mix(0.92, 1.08, smoothstep(0.2, 0.8, ground_variation));
	float chromatic_phase = ground_world_xz.x * 0.013 + ground_world_xz.y * 0.009;
	vec3 chromatic = 0.5 + 0.5 * cos(TAU * (chromatic_phase + vec3(0.0, 0.34, 0.68)));
	ALBEDO = mix(ALBEDO, chromatic * 0.22, chromatic_strength);
	ROUGHNESS = 0.95;
}
