// White-particle prepass. Renders the solver's foam/spray/bubbles into an
// offscreen buffer that the fluid composite consumes: R = optical density,
// G = density-weighted eye depth of the sprite's sphere surface. Sprites are
// soft and add up, so a lone particle is a faint fleck while a cluster
// saturates into a solid sheet of froth (the composite maps density to
// coverage). Depth is per fragment from the analytic sphere, so a sprite
// sliding behind scene geometry is clipped pixel by pixel instead of vanishing
// as a whole.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;
#ifdef FOG
// Liquid nitrogen vapour: faint puffs that add up into a cloud. Puffs keep one
// world size and fade in and out with the particle's swell (NITROGEN_FOG_SCALE
// when fully grown), so the cloud never reads as dots.
const float DENSITY = 0.035;
const float FOG_SPRITE = 0.7;
const float FOG_FULL_SWELL = 8.0;
#else
const float DENSITY = 0.3;
#endif
// A sprite smaller than this on screen shimmers as single-pixel glitter: it is
// grown to it and dimmed by the area ratio, so far foam keeps its coverage.
const float MIN_PIXELS = 3.0;

uniform sampler2D foam_tex : filter_nearest;
uniform int foam_tex_width = 256;
// Full sprite width (the quad mesh spans +-0.5), scaled per particle by the
// size foam_compact publishes.
uniform float billboard_size = 0.05;

varying vec3 center_view;
varying float sprite_size;
varying float sprite_alpha;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % foam_tex_width, int(INSTANCE_ID) / foam_tex_width);
	vec4 fd = texelFetch(foam_tex, texel, 0);
	// Size already folds in age dissolve, per-particle scale and speed; 0 means
	// dead and collapses the quad.
	sprite_size = fd.w > 0.001 ? fd.w * billboard_size : 0.0;
	sprite_alpha = 1.0;
	#ifdef FOG
	sprite_alpha = clamp(fd.w / FOG_FULL_SWELL, 0.0, 1.0);
	sprite_size = fd.w > 0.001 ? FOG_SPRITE : 0.0;
	#endif
	center_view = (VIEW_MATRIX * vec4(fd.xyz, 1.0)).xyz;
	// The Vulkan projection flips Y, so [1][1] is negative.
	float pixels = sprite_size * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y / max(-center_view.z, 0.01);
	if (sprite_size > 0.0 && pixels < MIN_PIXELS) {
		float grow = MIN_PIXELS / max(pixels, 1e-3);
		sprite_size *= grow;
		sprite_alpha /= grow * grow;
	}
	vec3 view_pos = center_view;
	view_pos.xy += VERTEX.xy * sprite_size;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	if (sprite_size <= 0.0 || r > 1.0) {
		discard;
	}
	float falloff = (1.0 - r * r) * (1.0 - r * r);
	float density = DENSITY * sprite_alpha * falloff;
	// Sphere-surface eye depth for this fragment: the quad sits at the sphere
	// centre and the written surface is its front hemisphere, bulging toward
	// the camera by up to the sprite radius.
	float nz = sqrt(max(1.0 - r * r, 0.0));
	float eye_depth = max(-center_view.z - nz * sprite_size * 0.5, 0.01);
	ALBEDO = vec3(density, eye_depth * density, 0.0);
}
