// Thickness prepass: additive accumulation of per-particle optical
// thickness, no depth test so all particles along the ray contribute.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 256;
uniform float particle_radius = 0.12;
uniform vec2 clip_z_m = vec2(-1e20, 1e20);

varying vec2 quad_uv;
varying float attrib;
varying float particle_z;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	particle_z = particle.z;
	attrib = particle.w;
	quad_uv = UV * 2.0 - 1.0;
	vec3 center_view = (VIEW_MATRIX * vec4(particle.xyz, 1.0)).xyz;
	vec3 view_pos = center_view + vec3(quad_uv * particle_radius, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	if (particle_z < clip_z_m.x || particle_z > clip_z_m.y) { discard; }
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	// R = thickness, G = attrib-weighted thickness (lava: temperature)
	float t = sqrt(1.0 - r2) * particle_radius * 2.0;
	ALBEDO = vec3(t, t * attrib, 0.0);
}
