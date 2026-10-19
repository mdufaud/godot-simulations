shader_type spatial;
render_mode world_vertex_coords, diffuse_burley, specular_schlick_ggx;

uniform vec3 albedo : source_color = vec3(0.3);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float texture_metres = 2.0;
// Corridor frame: depth runs along local -Z from the start door.
uniform mat4 world_to_corridor;
uniform mat4 corridor_to_world;
uniform float player_depth = 0.0;
uniform float rigid = 6.0;
uniform float stretch_length = 12.0;

varying vec3 real_local;
varying vec3 local_normal;

// Mirrors GrowingCorridorState.apparent_offset.
float apparent_offset(float offset) {
	float span = abs(offset);
	if (span <= rigid) {
		return offset;
	}
	return sign(offset) * (rigid + stretch_length * (1.0 - exp(-(span - rigid) / stretch_length)));
}

void vertex() {
	vec3 local = (world_to_corridor * vec4(VERTEX, 1.0)).xyz;
	real_local = local;
	local_normal = mat3(world_to_corridor) * NORMAL;
	local.z = -(player_depth + apparent_offset(-local.z - player_depth));
	VERTEX = (corridor_to_world * vec4(local, 1.0)).xyz;
}

void fragment() {
	// Texture in real coordinates: the tiles fold with the floor they print on.
	vec3 axis = abs(local_normal);
	vec2 uv = axis.y > 0.5 ? real_local.xz : (axis.x > 0.5 ? real_local.zy : real_local.xy);
	ALBEDO = albedo * texture(albedo_texture, uv / texture_metres).rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission * emission_energy;
}
