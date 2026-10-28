// Soft body surface: each vertex rides a tetrahedron of the solver's lattice, at
// fixed barycentric weights, read from the position texture (one texel per
// lattice vertex). Its normal follows the tetrahedron's deformation, F^-T n.
shader_type spatial;

uniform sampler2D position_tex : filter_nearest;
uniform int texture_width = 1024;
// First lattice vertex of this body in the solver's buffers.
instance uniform float vertex_offset = 0.0;
instance uniform vec3 body_color : source_color = vec3(0.85, 0.2, 0.3);

vec3 fetch(float local_index) {
	int i = int(local_index + vertex_offset + 0.5);
	return texelFetch(position_tex, ivec2(i % texture_width, i / texture_width), 0).xyz;
}

void vertex() {
	vec3 x0 = fetch(CUSTOM0.x);
	mat3 Ds = mat3(fetch(CUSTOM0.y) - x0, fetch(CUSTOM0.z) - x0, fetch(CUSTOM0.w) - x0);
	VERTEX = x0 + Ds * CUSTOM1.xyz;
	vec3 n = mat3(cross(Ds[1], Ds[2]), cross(Ds[2], Ds[0]), cross(Ds[0], Ds[1])) * CUSTOM2.xyz;
	NORMAL = length(n) > 1e-12 ? normalize(n) : vec3(0.0, 1.0, 0.0);
}

void fragment() {
	ALBEDO = body_color;
	ROUGHNESS = 0.3;
	SPECULAR = 0.6;
	SSS_STRENGTH = 0.4;
}
