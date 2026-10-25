// Depth prepass for screen-space fluid: billboards sphere impostors from the
// solver position texture and outputs linear eye depth to color (R).
//
// Overlaps used to resolve through a fragment-written DEPTH carrying the analytic
// sphere depth. That is exact, and it costs the whole pass: writing gl_FragDepth
// retires early-Z, so every fragment of every overlapping sprite shades before it
// can be rejected. Measured on the fire demo at Reference, 16384 sprites at
// 1920x1080: 14.95 ms with the depth write, 2.43 ms without. Neither of the levers
// the budget plan named comes close — halving the pass pixels saves 7.2 ms, and
// eight times fewer sprites saves only 6 ms, because the body covers the same
// screen area either way. The overdraw was the cost.
//
// So the quad is placed at the sphere's FRONT POLE instead (+radius towards the
// camera in view space) and the plane depth resolves the overlap. That is the
// conservative bound: the plane sits at the nearest point the sphere can reach, so
// the winner is the sprite that could be nearest, and the exact analytic depth is
// still what lands in the colour target. The winner can differ from the true
// nearest surface by at most one radius, which is the scale the bilateral filter
// downstream smooths at anyway.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 256;
uniform float particle_radius = 0.12;
uniform float cull_attribute_max = -1e20;
uniform vec2 clip_z_m = vec2(-1e20, 1e20);
uniform bool diagnostic_color_enabled = false;
// Optional per-particle data laid out like position_tex: z scales the sphere radius.
uniform sampler2D particle_data_tex : filter_nearest;
uniform bool particle_data_enabled = false;

varying vec2 quad_uv;
varying vec3 center_view;
varying float attrib;
varying float particle_z;
varying float radius;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	vec3 particle_pos = particle.xyz;
	particle_z = particle_pos.z;
	attrib = particle.w;
	if (attrib <= cull_attribute_max) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		float share = particle_data_enabled ? texelFetch(particle_data_tex, texel, 0).z : 0.0;
		radius = particle_radius * (share > 0.0 ? share : 1.0);
		quad_uv = UV * 2.0 - 1.0;
		center_view = (VIEW_MATRIX * vec4(particle_pos, 1.0)).xyz;
		vec3 view_pos = center_view + vec3(quad_uv * radius, radius);
		POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
	}
}

void fragment() {
	if (particle_z < clip_z_m.x || particle_z > clip_z_m.y) { discard; }
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	float nz = sqrt(1.0 - r2);
	vec3 sphere_view = center_view + vec3(quad_uv, nz) * radius;
	// Split eye depth into integer + fraction: 16F render target quantizes a
	// raw depth to ~1.6cm at 20m, destroying reconstructed normals. The split
	// itself stays exact only while floor(d) fits half-float integers, so clamp
	// at 2046m — beyond it the fluid is a faint distant sheet, not seam material.
	float eye_depth = -sphere_view.z;
	float depth_pack = min(eye_depth, 2046.0);
	// B = front-surface attribute (lava temperature) — depth test keeps nearest.
	ALBEDO = diagnostic_color_enabled ? vec3(0.04, 0.72, 0.87)
		: vec3(floor(depth_pack), depth_pack - floor(depth_pack), attrib);
}
