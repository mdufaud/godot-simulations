shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_never, fog_disabled;
#include "res://shaders/river/river_swe.gdshaderinc"
#include "res://shaders/river/river_waterfall_look.gdshaderinc"

// Coherent spilled water: a sheet per listed face on its particles' ballistic path (Chow 1959).

uniform sampler2D lip_list : filter_nearest;
uniform sampler2D lip_flow : filter_nearest;
uniform int lip_list_width = 256;
uniform int sheet_rows = 20;
// Whole-stream share of mean discharge (z) and largest thinning (w): as river_spill.comp.
uniform vec4 handover = vec4(0.0, 0.0, 0.25, 64.0);
uniform float thinning_exponent = 0.32;

// The sheet ends this far under the water it falls into, so the pool cuts it cleanly.
const float ENTRY_M = 0.02;
// A sheet runs down a wall this far off the rock, pushed out by up to DRAPE_REACH_CELLS in all, in DRAPE_STEPS a row.
const float CLEARANCE_M = 0.03;
const float DRAPE_REACH_CELLS = 2.0;
const int DRAPE_STEPS = 8;
const float FREE_SIDE_INSET_CELLS = 0.25;

varying vec3 world_position;
varying vec3 sheet_normal;
varying vec3 lip_across;
varying vec2 lip_point;
// How much the lip runs along world x and along world z (river_waterfall_look).
varying vec2 lip_weight;
varying float fall_m;
varying float presence;
// Seconds since the water left its lip.
varying float flight_s;
varying float stream_share;
// Share of the way to a free side of the sheet, which frays into threads instead of ending on a cell edge.
varying float side_share;

struct Column {
	vec2 velocity;
	float surface;
	float depth;
	float foam;
	vec2 normal;
	// Share leaving as a smooth nappe, the rest aerated (river_spill.comp).
	float nappe;
	// Where the sheet leaves, in cells.
	vec2 point;
	// 1 where no other spilling face meets this corner: the free side of a sheet.
	float free_side;
};

// Height of the water or ground under a point, smoothed for shading.
float receiving(vec2 point) {
	vec2 uv = river_swe_uv(point);
	vec4 water = texture(swe_surface, uv);
	return water.w > 0.004 ? water.z : texture(swe_terrain, uv).r;
}

// The same in the cell under the point, where a falling sheet stops: smoothed, a narrow gap would take in its walls.
float landing(vec2 point) {
	ivec2 cell = river_swe_cell(point);
	vec4 water = texelFetch(swe_surface, cell, 0);
	return water.w > 0.004 ? water.z : texelFetch(swe_terrain, cell, 0).r;
}

// Surface of the water in the cell under the point, far below when it is dry.
float water_level(vec2 point) {
	vec4 water = texelFetch(swe_surface, river_swe_cell(point), 0);
	return water.w > 0.004 ? water.z : -1.0e6;
}

// Rock as the ground mesh draws it: one vertex per solver cell, linear between.
float rock(vec2 point) {
	return texture(swe_terrain, river_swe_uv(point)).r;
}

Column cell_column(ivec2 cell) {
	vec4 own = texelFetch(swe_surface, cell, 0);
	vec4 flow = texelFetch(lip_flow, cell, 0);
	return Column(flow.xy, own.z, own.w, texelFetch(swe_foam, cell, 0).r, vec2(0.0), flow.z, vec2(cell) + 0.5, 0.0);
}

// Mean of the cells spilling at this corner, midway between the faces meeting there: a staircase leaves as a straight lip.
Column corner_column(ivec2 corner) {
	Column sum = Column(vec2(0.0), 0.0, 0.0, 0.0, vec2(0.0), 0.0, vec2(0.0), 0.0);
	float count = 0.0;
	float meeting = 0.0;
	ivec2 size = textureSize(swe_spill, 0);
	for (int k = 0; k < 4; k++) {
		ivec2 side = ivec2(k & 1, k >> 1);
		ivec2 cell = corner - 1 + side;
		if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, size))) continue;
		int faces = int(texelFetch(swe_spill, cell, 0).r + 0.5);
		int touching = (side.x == 0 ? 1 : 2) | (side.y == 0 ? 4 : 8);
		Column column = cell_column(cell);
		if ((faces & touching) == 0 || column.depth <= 0.004) continue;
		int spilled = faces & touching;
		vec2 normals = vec2(float(spilled & 1) - float((spilled >> 1) & 1), float((spilled >> 2) & 1) - float((spilled >> 3) & 1));
		float spilled_faces = abs(normals.x) + abs(normals.y);
		sum.point += column.point * spilled_faces + 0.5 * normals;
		meeting += spilled_faces;
		sum.normal += normals;
		sum.velocity += column.velocity;
		sum.surface += column.surface;
		sum.depth += column.depth;
		sum.foam += column.foam;
		sum.nappe += column.nappe;
		count += 1.0;
	}
	count = max(count, 1.0);
	return Column(sum.velocity / count, sum.surface / count, sum.depth / count, sum.foam / count, sum.normal, sum.nappe / count,
		meeting >= 2.0 ? sum.point / meeting : vec2(corner), float(meeting < 2.0));
}

float row_drop(int row, float drop) {
	float share = float(row) / float(max(sheet_rows - 1, 1));
	return drop * share * share;
}

void vertex() {
	vec4 entry = texelFetch(lip_list, ivec2(INSTANCE_ID % lip_list_width, INSTANCE_ID / lip_list_width), 0);
	presence = 0.0;
	if (entry.y < 0.5 || !swe_spill_enabled) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		ivec2 size = textureSize(swe_spill, 0);
		int index = int(entry.x + 0.5);
		ivec2 cell = ivec2(index % size.x, index / size.x);
		int face = int(entry.y + 0.5) - 1;
		vec2 normal = face < 2 ? vec2(float(1 - 2 * face), 0.0) : vec2(0.0, float(5 - 2 * face));
		vec2 tangent = vec2(-normal.y, normal.x);
		float cell_m = swe_region_m.z / float(size.x);
		float across = UV.x * 2.0 - 1.0;
		vec2 end = vec2(cell) + 0.5 + 0.5 * normal;
		Column first = corner_column(ivec2(round(end - 0.5 * tangent)));
		Column last = corner_column(ivec2(round(end + 0.5 * tangent)));
		// Corners are shared with the neighbouring faces, and the middle lies between them, so the strips join edge to edge.
		Column column = across < -0.5 ? first : (across > 0.5 ? last : Column(0.5 * (first.velocity + last.velocity),
			0.5 * (first.surface + last.surface), 0.5 * (first.depth + last.depth), 0.5 * (first.foam + last.foam),
			first.normal + last.normal, 0.5 * (first.nappe + last.nappe),
			0.5 * (first.point + last.point), 0.5 * (first.free_side + last.free_side)));
		side_share = column.free_side;
		vec2 base = swe_region_m.xy + column.point * cell_m;
		// Landings are read along the path from the grid face itself, which the straightened lip may sit inside of.
		vec2 face_point = swe_region_m.xy + (end + 0.5 * across * tangent) * cell_m;
		vec3 shift = vec3(base.x - face_point.x, 0.0, base.y - face_point.y);
		vec2 facing = length(column.normal) > 0.01 ? normalize(column.normal) : normal;
		// Deep enough to reach the ground below the face, below the path itself, or the foot of the wall it runs down.
		float drop = column.surface - min(landing(face_point + facing * cell_m), landing(face_point + facing * DRAPE_REACH_CELLS * cell_m));
		for (int k = 0; k < 3; k++) {
			float time_s = sqrt(2.0 * max(drop, 0.01) / GRAVITY_M_S2);
			drop = max(drop, column.surface - landing(face_point + column.velocity * time_s));
		}
		// Never above its lip, however the water around it is averaged: every row below it then falls.
		drop = max(drop, 0.0) + 0.25;
		int row = int(round(UV.y * float(sheet_rows - 1)));
		float top = column.surface;
		vec3 point = vec3(base.x, top, base.y);
		vec3 along = vec3(facing.x, 0.0, facing.y);
		float fallen = 0.0;
		flight_s = 0.0;
		float pushed = 0.0;
		vec3 previous = vec3(face_point.x, top, face_point.y);
		// A free side falls along the boundary with the rock beside it: ground and pool are read just inside the strip.
		vec2 inside = -across * column.free_side * tangent * FREE_SIDE_INSET_CELLS * cell_m;
		for (int k = 1; k <= row; k++) {
			float drop_k = row_drop(k, drop);
			float time_s = sqrt(2.0 * drop_k / GRAVITY_M_S2);
			vec3 next = vec3(face_point.x + column.velocity.x * time_s + facing.x * pushed, top - drop_k,
				face_point.y + column.velocity.y * time_s + facing.y * pushed);
			// Water meeting the wall below its lip runs down it: pushed out of the rock, never through it.
			for (int s = 0; s < DRAPE_STEPS && next.y < rock(next.xz + inside) + CLEARANCE_M && pushed < DRAPE_REACH_CELLS * cell_m; s++) {
				pushed += DRAPE_REACH_CELLS * cell_m / float(DRAPE_STEPS);
				next.xz += facing * DRAPE_REACH_CELLS * cell_m / float(DRAPE_STEPS);
			}
			// Just past the face, so the row at the face falls on the side it spills to.
			float water = water_level(next.xz + inside + facing * 0.001);
			bool grounded = next.y < rock(next.xz + inside) + CLEARANCE_M;
			if (next.y <= water || grounded) {
				// Met its pool or ground too gentle to run down; never above the row before, as rock may be a spur beside it.
				float stop = next.y <= water ? water - ENTRY_M : min(rock(next.xz + inside) + CLEARANCE_M, previous.y);
				point = vec3(next.x, stop, next.z) + shift;
				flight_s = time_s;
				break;
			}
			point = next + shift;
			fallen = drop_k;
			flight_s = time_s;
			along = normalize(next - previous);
			previous = next;
		}
		VERTEX = point;
		world_position = point;
		lip_across = vec3(-facing.y, 0.0, facing.x);
		sheet_normal = normalize(cross(lip_across, along));
		lip_point = base;
		lip_weight = facing.yx * facing.yx;
		lip_weight *= lip_weight;
		// The face's stream against the mean: thinner ones break up sooner and, below handover.z, fall as drops.
		float ratio = unit_discharge_m2_s > 0.0 ? column.depth * max(dot(column.velocity, facing), 0.0) / unit_discharge_m2_s : 1.0;
		stream_share = clamp(ratio / handover.z, 0.0, 1.0);
		float thinning = pow(clamp(1.0 / max(ratio, 0.0001), 1.0, handover.w), thinning_exponent);
		fall_m = fallen * thinning + max(column.foam, 1.0 - column.nappe) * breakup_length_m;
		// A trickle far below whole-stream share is a film on the rock, not a fall.
		presence = smoothstep(0.2 * handover.z, 0.6 * handover.z, ratio);
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(point, 1.0));
	}
}

void fragment() {
	if (presence <= 0.002) { discard; }
	vec3 view_normal = normalize((VIEW_MATRIX * vec4(sheet_normal, 0.0)).xyz);
	if (dot(view_normal, VIEW) < 0.0) { view_normal = -view_normal; }
	float above_pool_m = world_position.y - receiving(world_position.xz);
	vec3 view_across = normalize((VIEW_MATRIX * vec4(lip_across, 0.0)).xyz);
	WaterfallLook look = waterfall_look(view_normal, view_across, fall_m, flight_s, lip_point, lip_weight, stream_share, side_share,
		above_pool_m, VIEW, SCREEN_UV);
	NORMAL = look.normal;
	ALBEDO = look.albedo;
	EMISSION = look.emission;
	ROUGHNESS = look.roughness;
	SPECULAR = look.specular;
	BACKLIGHT = look.backlight;
	// Clear water seen edge-on is a thin film, not a glossy ribbon; aerated water shows its body from any side.
	float edge_on = mix(smoothstep(0.08, 0.35, abs(dot(view_normal, VIEW))), 1.0, look.foam);
	ALPHA = presence * spill_apart(above_pool_m, fall_m) * look.coverage * edge_on;
}
