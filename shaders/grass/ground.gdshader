shader_type spatial;

// Visual soil under the grass. Displaces the plane with the same heightmap
// sampling the blade shader uses (world xz over the texture size), so the
// ground, the grass and the HeightMapShape3D collision all follow one field.
uniform sampler2D heightmap : filter_linear, repeat_enable;
uniform float heightmap_scale = 5.0;
uniform vec3 albedo : source_color = vec3(0.04, 0.11, 0.02);

float terrain_height(vec2 world_xz, vec2 tex_size) {
	return (texture(heightmap, world_xz / tex_size).x - 0.5) * heightmap_scale;
}

void vertex() {
	vec2 tex_size = vec2(textureSize(heightmap, 0));
	vec2 world_xz = NODE_POSITION_WORLD.xz;
	VERTEX.y += terrain_height(world_xz, tex_size);
	// Central differences: a displaced plane keeps flat normals otherwise.
	float eps = 1.0;
	float h = terrain_height(world_xz, tex_size);
	float hx = terrain_height(world_xz + vec2(eps, 0.0), tex_size);
	float hz = terrain_height(world_xz + vec2(0.0, eps), tex_size);
	NORMAL = normalize(vec3(h - hx, eps, h - hz));
}

void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = 0.95;
}
