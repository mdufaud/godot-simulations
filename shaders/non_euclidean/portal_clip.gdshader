shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 albedo : source_color = vec3(0.35);
uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform bool clip_enabled = false;
uniform vec4 clip_plane = vec4(0.0, 0.0, 1.0, 0.0);

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clip_enabled && dot(clip_plane.xyz, world_position) + clip_plane.w < 0.0) {
		discard;
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
