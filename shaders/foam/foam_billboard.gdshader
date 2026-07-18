// White-particle prepass. Renders the solver's foam/spray/bubbles into an
// offscreen coverage buffer that the fluid composite consumes: R = coverage,
// G = linear eye depth of the sprite centre. Foam is opaque white in the
// composite (col * (1 - foam) + foam), so overlapping sprites build a solid
// sheet of froth instead of the faint additive dots an over-the-top layer gives.
// Depth is written so overlapping sprites resolve to the nearest one.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D foam_tex : filter_nearest;
uniform int foam_tex_width = 256;
// Full sprite width (the quad mesh spans +-0.5). SebLague: uniform scale 0.02,
// vertScale = scale * 2 * ... = 0.04 at his smoothing radius of 0.2, i.e. h/5.
// Scaled to our h = 0.25. Sprites must be far smaller than the smoothing radius
// or they read as golf balls instead of froth.
uniform float billboard_size = 0.05;

varying float center_depth;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % foam_tex_width, int(INSTANCE_ID) / foam_tex_width);
	vec4 fd = texelFetch(foam_tex, texel, 0);
	// Size already folds in age dissolve, per-particle scale and speed; 0 means
	// dead and collapses the quad.
	float s = fd.w > 0.001 ? fd.w * billboard_size : 0.0;
	vec3 view_pos = (VIEW_MATRIX * vec4(fd.xyz, 1.0)).xyz;
	center_depth = -view_pos.z;
	view_pos.xy += VERTEX.xy * s;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	if (r > 1.0) {
		discard;
	}
	ALBEDO = vec3(1.0, center_depth, 0.0);
}
