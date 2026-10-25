uniform sampler2D swe_surface : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_foam : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_terrain : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_spill : filter_linear, repeat_disable, hint_default_black;
uniform vec4 swe_region_m = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool swe_enabled = false;
uniform bool swe_spill_enabled = false;
// Bed slope past which the solver pours the water as particles: no live water surface is steeper.
uniform float swe_spill_slope = 1.5;
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

// The sample point of the solver cell containing a point: heights there do not blend across a spill step.
vec2 river_swe_cell_uv(vec2 point) {
	return (vec2(river_swe_cell(point)) + 0.5) / vec2(textureSize(swe_spill, 0));
}

// Bilinear share of the four nearest cells holding water within tolerance of a height: which pool a point is in.
float river_swe_level_share(vec2 point, float height, float tolerance) {
	ivec2 size = textureSize(swe_surface, 0);
	vec2 c = river_swe_uv(point) * vec2(size) - 0.5;
	ivec2 lo = ivec2(floor(c));
	vec2 f = c - vec2(lo);
	float share = 0.0;
	for (int k = 0; k < 4; k++) {
		ivec2 corner = ivec2(k & 1, k >> 1);
		vec4 cell = texelFetch(swe_surface, clamp(lo + corner, ivec2(0), size - 1), 0);
		vec2 w = mix(1.0 - f, f, vec2(corner));
		share += w.x * w.y * float(cell.w > 0.004 && abs(cell.z - height) < tolerance);
	}
	return share;
}

// Bits 0-3: the cell spills over its east, west, north, south face; bits 4-7: water spills onto it over that face.
int river_spill_faces(vec2 point) {
	return swe_spill_enabled ? int(texelFetch(swe_spill, river_swe_cell(point), 0).r + 0.5) : 0;
}
