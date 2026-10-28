shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled, diffuse_lambert_wrap, fog_disabled;

// Broken-up spilled water: each spill particle drawn as a soft white streak along its velocity.

uniform sampler2D positions : filter_nearest;
uniform sampler2D motions : filter_nearest;
uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform int texture_width = 256;
uniform float radius_m = 0.09;
uniform float breakup_length_m = 3.0;
uniform float aeration_strength = 1.0;
uniform float simulation_time_s = 0.0;

// Seconds of motion each streak spans, as a camera exposure would blur it.
const float EXPOSURE_S = 0.04;
// Drawn break-up share starts above zero for a live particle (river_spill.comp DROP_OFFSET_M).
const float DROP_OFFSET_M = 0.01;
// Fractions of the break-up length over which the streaks take over from the sheet, as river_waterfall_look.
const vec2 BREAKUP_SHARE = vec2(0.1, 1.0);
const float OPACITY = 0.45;
// Streaks fade into whatever they pass through over this depth, rather than cutting along it.
const float SOFT_DEPTH_M = 0.15;

varying vec2 quad;
varying float opacity;
varying float seed;

void vertex() {
	ivec2 texel = ivec2(INSTANCE_ID % texture_width, INSTANCE_ID / texture_width);
	vec4 body = texelFetch(positions, texel, 0);
	vec4 motion = texelFetch(motions, texel, 0);
	float broken = smoothstep(BREAKUP_SHARE.x, BREAKUP_SHARE.y, (body.w - DROP_OFFSET_M) / max(breakup_length_m, 0.01));
	// A small drop scatters little light: alone, its blur would read as a white needle.
	opacity = body.w > 0.0 ? OPACITY * broken * smoothstep(0.25, 0.6, aeration_strength) * motion.w : 0.0;
	if (opacity < 0.005) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		// PCG hash: drops leave a lip at a steady rate, so any regular seed lines their streaks up into chevrons.
		uint h = uint(INSTANCE_ID) * 747796405u + 2891336453u;
		h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
		h = (h >> 22u) ^ h;
		seed = float(h & 0xFFFFu) / 65535.0;
		float shutter = mix(0.4, 1.6, float(h >> 16u) / 65535.0);
		vec3 center = (VIEW_MATRIX * vec4(body.xyz, 1.0)).xyz;
		vec2 velocity = (VIEW_MATRIX * vec4(motion.xyz, 0.0)).xy;
		vec2 along = length(velocity) > 1.0e-4 ? normalize(velocity) : vec2(0.0, -1.0);
		vec2 across = vec2(-along.y, along.x);
		float radius = radius_m * motion.w * mix(0.6, 1.4, seed);
		float trail = radius + length(velocity) * EXPOSURE_S * shutter;
		quad = UV * 2.0 - 1.0;
		vec2 offset = across * quad.x * radius + along * (quad.y + shutter - 1.0) * trail;
		VERTEX = center + vec3(offset, 0.0);
		NORMAL = vec3(0.0, 0.0, 1.0);
		POSITION = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
	}
}

void fragment() {
	if (opacity < 0.005) { discard; }
	// Wide behind and pointed ahead: falling, each streak is a downward V.
	float ahead = quad.y * 0.5 + 0.5;
	float shape = 1.0 - smoothstep(0.35, 1.0, length(vec2(quad.x / mix(1.0, 0.25, ahead), quad.y)));
	float grain = texture(turbulence_texture, quad * 0.25 + vec2(seed, simulation_time_s * 0.3)).r;
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	float room = -scene.z / scene.w - (-VERTEX.z);
	ALBEDO = vec3(0.86, 0.92, 0.94) * mix(0.85, 1.0, grain);
	ROUGHNESS = 1.0;
	BACKLIGHT = vec3(0.6, 0.65, 0.65);
	NORMAL = vec3(0.0, 0.0, 1.0);
	ALPHA = opacity * shape * mix(0.5, 1.2, grain) * smoothstep(0.0, SOFT_DEPTH_M, room);
}
