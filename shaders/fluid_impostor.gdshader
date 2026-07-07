// Depth prepass for screen-space fluid: billboards sphere impostors from the
// PBF position texture, outputs linear eye depth to color (R) and analytic
// sphere depth to the depth buffer so overlaps resolve to the nearest surface.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 256;
uniform float particle_radius = 0.12;

varying vec2 quad_uv;
varying vec3 center_view;
varying float attrib;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	vec3 particle_pos = particle.xyz;
	attrib = particle.w;
	quad_uv = UV * 2.0 - 1.0;
	center_view = (VIEW_MATRIX * vec4(particle_pos, 1.0)).xyz;
	vec3 view_pos = center_view + vec3(quad_uv * particle_radius, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	float nz = sqrt(1.0 - r2);
	vec3 sphere_view = center_view + vec3(quad_uv, nz) * particle_radius;
	vec4 clip = PROJECTION_MATRIX * vec4(sphere_view, 1.0);
	DEPTH = clip.z / clip.w;
	// Split eye depth into integer + fraction: 16F render target quantizes a
	// raw depth to ~1.6cm at 20m, destroying reconstructed normals
	// B = front-surface attribute (lava: temperature) — depth test keeps nearest
	float eye_depth = -sphere_view.z;
	ALBEDO = vec3(floor(eye_depth), eye_depth - floor(eye_depth), attrib);
}
