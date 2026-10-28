uniform sampler2D swe_surface : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_foam : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_terrain : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_spill : filter_linear, repeat_disable, hint_default_black;
// Per solver cell, the surface height at its -x-z, +x-z, -x+z and +x+z corners (river_swe.comp); infinite where it draws none.
uniform sampler2D swe_corners : filter_nearest, repeat_disable, hint_default_black;
uniform vec4 swe_region_m = vec4(0.0, 0.0, 1.0, 1.0);
// Shallower water is a dry cell (river_swe_solver.gd WET_DEPTH_M).
uniform float swe_wet_depth_m = 0.0;
uniform bool swe_enabled = false;
uniform bool swe_spill_enabled = false;
uniform float swe_blend = 1.0;

vec2 river_swe_uv(vec2 point) {
	return (point - swe_region_m.xy) / swe_region_m.zw;
}

float river_swe_edge(vec2 point) {
	vec2 edge = min(point - swe_region_m.xy, swe_region_m.xy + swe_region_m.zw - point);
	return min(edge.x, edge.y);
}

float river_swe_weight(vec2 point) {
	return float(swe_enabled) * swe_blend * smoothstep(1.0, 2.5, river_swe_edge(point));
}

float river_swe_height(vec2 point, float original) {
	float weight = river_swe_weight(point);
	if (weight <= 0.0) { return original; }
	vec4 state = texture(swe_surface, river_swe_uv(point));
	return mix(original, state.z, weight);
}

ivec2 river_swe_cell(vec2 point) {
	ivec2 size = textureSize(swe_spill, 0);
	return clamp(ivec2(floor(river_swe_uv(point) * vec2(size))), ivec2(0), size - 1);
}

// One corner of a swe_corners texel. v[i] with a runtime i compiles to OpVectorExtractDynamic, which Godot's SPIR-V pass
// rejects at every compile.
float river_swe_corner(vec4 corners, int corner) {
	return corner == 0 ? corners.x : (corner == 1 ? corners.y : (corner == 2 ? corners.z : corners.w));
}

// Bits 0-3: the cell spills over its east, west, north, south face; bits 4-7: water spills onto it over that face.
int river_spill_faces(vec2 point) {
	return swe_spill_enabled ? int(texelFetch(swe_spill, river_swe_cell(point), 0).r + 0.5) : 0;
}
