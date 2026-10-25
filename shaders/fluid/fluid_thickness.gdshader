// Thickness prepass: additive accumulation of per-particle optical
// thickness, no depth test so all particles along the ray contribute.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 256;
uniform float particle_radius = 0.12;
uniform float cull_attribute_max = -1e20;
uniform vec2 clip_z_m = vec2(-1e20, 1e20);
// Optional per-particle data laid out like position_tex: a world x, z point (x, y) whose coordinate along the world axis
// nearest the screen horizontal is averaged into G, the radius share (z) and a value averaged into B (w).
uniform sampler2D particle_data_tex : filter_nearest;
uniform bool particle_data_enabled = false;

varying vec2 quad_uv;
varying float attrib;
varying float particle_z;
varying vec2 carried;
varying float radius;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	particle_z = particle.z;
	attrib = particle.w;
	vec4 data = particle_data_enabled ? texelFetch(particle_data_tex, texel, 0) : vec4(0.0);
	vec2 screen_x = abs(INV_VIEW_MATRIX[0].xz);
	carried = vec2(mix(data.x, data.y, smoothstep(0.3, 0.7, screen_x.y / max(screen_x.x + screen_x.y, 0.001))), data.w);
	radius = particle_radius * (data.z > 0.0 ? data.z : 1.0);
	if (attrib <= cull_attribute_max) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		quad_uv = UV * 2.0 - 1.0;
		vec3 center_view = (VIEW_MATRIX * vec4(particle.xyz, 1.0)).xyz;
		vec3 view_pos = center_view + vec3(quad_uv * radius, 0.0);
		POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
	}
}

void fragment() {
	if (particle_z < clip_z_m.x || particle_z > clip_z_m.y) { discard; }
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	// R = thickness, G = attrib-weighted thickness (lava: temperature), or G B = thickness-weighted carried values
	float t = sqrt(1.0 - r2) * radius * 2.0;
	ALBEDO = particle_data_enabled ? vec3(t, t * carried) : vec3(t, t * attrib, 0.0);
}
