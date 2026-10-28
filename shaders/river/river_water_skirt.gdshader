shader_type spatial;
render_mode world_vertex_coords, cull_disabled;
#include "res://shaders/river/river_swe.gdshaderinc"

// The side of the water where its cell surface ends above lower ground (river_water.gdshader draws only the top):
// one quad per cell edge, from the higher surface down to its own bed or to the lower surface, flat where both meet.
// Under a lip it is the water's thickness at the brink, behind the sheet falling from the same edge.

uniform ivec2 cell_grid = ivec2(0);
uniform float cell_size_m = 0.125;
uniform vec2 domain_m = vec2(1.0);
uniform vec2 domain_origin_m = vec2(0.0);
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);

const vec3 FOAM_COLOR = vec3(0.82, 0.87, 0.83);
// Thinner sides than this are left out: the surfaces on both sides meet.
const float MIN_SIDE_M = 0.002;
// Streaks of foam carried down a side: their width across it, length and speed down it.
const vec2 STREAK_SCALE_PER_M = vec2(14.0, 1.6);
const float STREAK_SPEED_M_S = 2.5;

varying vec3 world_position;
varying vec3 outward;
varying float aeration;
varying float top_m;

float value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 f = fract(point);
	vec4 corners = fract(sin(vec4(dot(cell, vec2(127.1, 311.7)), dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7)),
		dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7)), dot(cell + vec2(1.0), vec2(127.1, 311.7)))) * 43758.5453);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(corners.x, corners.y, f.x), mix(corners.z, corners.w, f.x), f.y);
}

ivec2 solver_cell(vec2 point) {
	ivec2 size = textureSize(swe_corners, 0);
	return clamp(ivec2(floor(river_swe_uv(point) * vec2(size))), ivec2(0), size - 1);
}

void vertex() {
	int quad = VERTEX_ID / 4;
	int k = VERTEX_ID % 4;
	int edge = quad % 2;
	ivec2 cell = ivec2((quad / 2) % cell_grid.x, (quad / 2) / cell_grid.x);
	ivec2 step = edge == 0 ? ivec2(1, 0) : ivec2(0, 1);
	int end = k & 1;
	vec2 origin = domain_origin_m - domain_m * 0.5;
	vec2 point = origin + vec2(cell + (edge == 0 ? ivec2(1, end) : ivec2(end, 1))) * cell_size_m;
	ivec2 own = solver_cell(origin + (vec2(cell) + 0.5) * cell_size_m);
	ivec2 other = solver_cell(origin + (vec2(cell + step) + 0.5) * cell_size_m);
	// Corner indices -x-z, +x-z, -x+z, +x+z: this cell's two on the shared edge, and the neighbour's at the same points.
	vec4 own_corners = texelFetch(swe_corners, own, 0);
	vec4 other_corners = texelFetch(swe_corners, other, 0);
	vec2 own_ends = edge == 0 ? own_corners.yw : own_corners.zw;
	vec2 other_ends = edge == 0 ? other_corners.xz : other_corners.xy;
	own_ends = mix(own_ends, vec2(-1.0e6), isinf(own_ends));
	other_ends = mix(other_ends, vec2(-1.0e6), isinf(other_ends));
	// Which side hangs is decided for the whole edge, so a side meeting its neighbour at one end does not flip there.
	bool own_upper = own_ends.x + own_ends.y >= other_ends.x + other_ends.y;
	ivec2 upper = own_upper ? own : other;
	// Selected, not indexed: v[end] compiles to OpVectorExtractDynamic, which Godot's SPIR-V pass rejects.
	vec2 upper_ends = own_upper ? own_ends : other_ends;
	vec2 lower_ends = own_upper ? other_ends : own_ends;
	float top = end == 0 ? upper_ends.x : upper_ends.y;
	float low = min(end == 0 ? lower_ends.x : lower_ends.y, top);
	outward = vec3(float(step.x), 0.0, float(step.y)) * (own_upper ? 1.0 : -1.0);
	aeration = clamp(texelFetch(swe_foam, upper, 0).r, 0.0, 0.6);
	float bed = texelFetch(swe_terrain, upper, 0).r;
	float bottom = max(low, bed);
	if (top < -1.0e5) { top = bed; }
	if (!swe_enabled || other == own || top - bottom < MIN_SIDE_M) { bottom = top; }
	VERTEX = vec3(point.x, k >= 2 ? bottom : top, point.y);
	top_m = top;
	world_position = VERTEX;
}

void fragment() {
	// Seen from inside its water the side is hidden by the surface above it.
	if (dot(CAMERA_POSITION_WORLD - world_position, outward) < 0.0) { discard; }
	float across = dot(world_position.xz, vec2(-outward.z, outward.x));
	float streak = value_noise(vec2(across, world_position.y + TIME * STREAK_SPEED_M_S) * STREAK_SCALE_PER_M);
	float depth = max(top_m - world_position.y, 0.0);
	float white = aeration * mix(0.72, 1.0, streak) * mix(1.0, 0.8, smoothstep(0.2, 1.0, depth));
	ALBEDO = mix(deep_color, FOAM_COLOR, white);
	NORMAL = normalize((VIEW_MATRIX * vec4(outward, 0.0)).xyz);
	ROUGHNESS = mix(0.15, 0.7, aeration);
	SPECULAR = mix(0.35, 0.12, aeration);
}
