shader_type spatial;
render_mode cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;
#include "res://shaders/river/river_swe.gdshaderinc"

// Spilled water composite: fluid_depth_tex = eye depth (R + G) and free-fall drop (B), thickness_tex = optical depth.

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
uniform sampler2D fluid_depth_tex : filter_nearest;
uniform sampler2D thickness_tex : filter_linear;
uniform float sample_diameter_m = 0.19;

#include "res://shaders/river/river_waterfall_look.gdshaderinc"

// Opaque where two particle samples overlap (the sheet), faint for a lone particle thrown off a rock.
const vec2 COVERAGE_SAMPLES = vec2(0.25, 2.0);
// Normals span this many depth texels, wider than one sphere bump, so the sheet shades as a sheet, not as beads.
const float NORMAL_SPAN_TEXELS = 3.0;
// Drop below which a spill is a splash off a rock rather than a fall, and the height above a pool where it merges.
const vec2 SHORT_SPILL_M = vec2(0.4, 1.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Share of the four nearest solver cells whose own pool covers this point. Each cell keeps its lip sharp; weighing
// them bilinearly draws the pool's edge along the water instead of stepping it cell by cell.
float under_cells(vec2 point, float height) {
	ivec2 size = textureSize(swe_surface, 0);
	vec2 c = river_swe_uv(point) * vec2(size) - 0.5;
	ivec2 lo = ivec2(floor(c));
	vec2 f = c - vec2(lo);
	float share = 0.0;
	for (int k = 0; k < 4; k++) {
		ivec2 corner = ivec2(k & 1, k >> 1);
		ivec2 cell = clamp(lo + corner, ivec2(0), size - 1);
		vec4 own = texelFetch(swe_surface, cell, 0);
		float source = texelFetch(swe_spill, cell, 0).b;
		vec2 w = mix(1.0 - f, f, vec2(corner));
		share += w.x * w.y * float(own.w > 0.004 && height < own.z + source * sample_diameter_m * 0.5);
	}
	return share;
}

float fluid_depth(vec2 uv) {
	vec2 rg = texture(fluid_depth_tex, uv).rg;
	return rg.x + rg.y;
}

vec3 eye_position(vec2 uv, float eye_depth, mat4 inv_projection) {
	vec4 ray = inv_projection * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 direction = ray.xyz / ray.w;
	return direction * (eye_depth / -direction.z);
}

void fragment() {
	float raw = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene_depth = -scene.z / scene.w;
	vec2 texel = 1.0 / vec2(textureSize(fluid_depth_tex, 0));
	float depth = fluid_depth(SCREEN_UV);
	// The half-resolution depth is grown by one texel so the edge alpha comes from the smooth thickness instead.
	if (depth <= 0.001) {
		for (int i = 0; i < 4; i++) {
			vec2 offset = vec2(float(i == 0) - float(i == 1), float(i == 2) - float(i == 3)) * texel;
			float neighbor = fluid_depth(SCREEN_UV + offset);
			if (neighbor > 0.001 && (depth <= 0.001 || neighbor < depth)) { depth = neighbor; }
		}
	}
	if (depth <= 0.001 || depth > scene_depth) { discard; }

	// One-sided differences, the smaller side on each axis, so silhouettes keep their normals.
	vec3 center = eye_position(SCREEN_UV, depth, INV_PROJECTION_MATRIX);
	texel *= NORMAL_SPAN_TEXELS;
	float right = fluid_depth(SCREEN_UV + vec2(texel.x, 0.0));
	float left = fluid_depth(SCREEN_UV - vec2(texel.x, 0.0));
	float up = fluid_depth(SCREEN_UV + vec2(0.0, texel.y));
	float down = fluid_depth(SCREEN_UV - vec2(0.0, texel.y));
	vec3 dx = eye_position(SCREEN_UV + vec2(texel.x, 0.0), right, INV_PROJECTION_MATRIX) - center;
	if (left > 0.001 && (abs(left - depth) < abs(right - depth) || right <= 0.001)) {
		dx = center - eye_position(SCREEN_UV - vec2(texel.x, 0.0), left, INV_PROJECTION_MATRIX);
	}
	vec3 dy = eye_position(SCREEN_UV + vec2(0.0, texel.y), up, INV_PROJECTION_MATRIX) - center;
	if (down > 0.001 && (abs(down - depth) < abs(up - depth) || up <= 0.001)) {
		dy = center - eye_position(SCREEN_UV - vec2(0.0, texel.y), down, INV_PROJECTION_MATRIX);
	}
	vec3 view_normal = normalize(cross(dy, dx));
	if (dot(view_normal, center) > 0.0) { view_normal = -view_normal; }
	vec3 world = (INV_VIEW_MATRIX * vec4(center, 1.0)).xyz;
	// Inside a pool the particles are that pool's water, and over the lip they pour from, the pool's own surface.
	// The cells' own values keep the lip sharp, the filtered ones keep a splash off a rock round.
	vec2 swe_uv = river_swe_uv(world.xz);
	vec4 pool = texture(swe_surface, swe_uv);
	float source = texture(swe_spill, swe_uv).b;
	if (under_cells(world.xz, world.y) > 0.5
		|| (pool.w > 0.004 && world.y < pool.z + source * sample_diameter_m * 0.5)) { discard; }

	float drop_m = texture(fluid_depth_tex, SCREEN_UV).b;
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(view_normal, 0.0)).xyz;
	// The sheet runs across its horizontal normal, so its streaks follow that axis.
	float facing_x = smoothstep(0.3, 0.7, abs(world_normal.x) / max(abs(world_normal.x) + abs(world_normal.z), 0.001));
	float across_m = mix(world.x, world.z, facing_x);
	float above_pool_m = world.y - (pool.w > 0.004 ? pool.z : texture(swe_terrain, swe_uv).r);
	WaterfallLook look = waterfall_look(world, view_normal, drop_m, across_m, above_pool_m, VIEW_MATRIX, VIEW, SCREEN_UV);
	NORMAL = look.normal;
	LIGHT_VERTEX = center;
	ALBEDO = look.albedo;
	EMISSION = look.emission;
	ROUGHNESS = look.roughness;
	SPECULAR = look.specular;
	BACKLIGHT = look.backlight;
	float samples = (texture(thickness_tex, SCREEN_UV).r + look.fray * 0.04 * look.thin) / sample_diameter_m;
	// Water spilling a short way off a rock into a pool merges with it; a long fall keeps its sheet down to the pool.
	float merged = 1.0 - max(smoothstep(0.0, SHORT_SPILL_M.x, above_pool_m), smoothstep(SHORT_SPILL_M.x, SHORT_SPILL_M.y, drop_m));
	ALPHA = smoothstep(COVERAGE_SAMPLES.x, COVERAGE_SAMPLES.y, samples) * (1.0 - merged);
}
