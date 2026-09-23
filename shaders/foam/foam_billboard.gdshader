// White-particle prepass. Renders the solver's foam/spray/bubbles into an
// offscreen coverage buffer that the fluid composite consumes: R = coverage,
// G = coverage-weighted eye depth of the sprite's sphere surface. Foam is blended by
// coverage in the composite (col * (1 - foam) + foam), so overlapping sprites
// build a solid sheet of froth while the soft rim antialiases every sprite
// edge instead of popping as a hard circle. Depth is per fragment from the
// analytic sphere, so a sprite sliding behind scene geometry is clipped pixel
// by pixel instead of vanishing as a whole.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D foam_tex : filter_nearest;
uniform int foam_tex_width = 256;
// Full sprite width (the quad mesh spans +-0.5). SebLague: uniform scale 0.02,
// vertScale = scale * 2 * ... = 0.04 at his smoothing radius of 0.2, i.e. h/5.
// Scaled to our h = 0.25. Sprites must be far smaller than the smoothing radius
// or they read as golf balls instead of froth.
uniform float billboard_size = 0.05;

varying vec3 center_view;
varying float sprite_size;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % foam_tex_width, int(INSTANCE_ID) / foam_tex_width);
	vec4 fd = texelFetch(foam_tex, texel, 0);
	// Size already folds in age dissolve, per-particle scale and speed; 0 means
	// dead and collapses the quad.
	sprite_size = fd.w > 0.001 ? fd.w * billboard_size : 0.0;
	center_view = (VIEW_MATRIX * vec4(fd.xyz, 1.0)).xyz;
	vec3 view_pos = center_view;
	view_pos.xy += VERTEX.xy * sprite_size;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	if (sprite_size <= 0.0) {
		discard;
	}
	float r = length(UV - 0.5) * 2.0;
	if (r > 1.0) {
		discard;
	}
	// Coverage fades over the outer ~20% of the disc; the interior saturates at
	// 1. The wide solid core matters because the prepass is front-most-wins: a
	// soft rim over a sparse field overwrites neighbours' interiors and reads
	// as dotted grain instead of a merged froth sheet.
	float coverage = smoothstep(1.0, 0.78, r);
	// Sphere-surface eye depth for this fragment: the quad sits at the sphere
	// centre and the written surface is its front hemisphere, bulging toward
	// the camera by up to the sprite radius.
	float nz = sqrt(max(1.0 - r * r, 0.0));
	float eye_depth = max(-center_view.z - nz * sprite_size * 0.5, 0.01);
	ALBEDO = vec3(coverage, eye_depth * coverage, 0.0);
}
