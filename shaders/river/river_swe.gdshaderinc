uniform sampler2D swe_surface : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_foam : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D swe_terrain : filter_linear, repeat_disable, hint_default_black;
uniform vec4 swe_region_m = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool swe_enabled = false;

vec2 river_swe_uv(vec2 point) {
	return (point - swe_region_m.xy) / swe_region_m.zw;
}

float river_swe_edge(vec2 point) {
	vec2 edge = min(point - swe_region_m.xy, swe_region_m.xy + swe_region_m.zw - point);
	return min(edge.x, edge.y);
}

float river_swe_weight(vec2 point) {
	return float(swe_enabled) * smoothstep(1.0, 2.5, river_swe_edge(point));
}

float river_swe_height(vec2 point, float original) {
	float weight = river_swe_weight(point);
	if (weight <= 0.0) { return original; }
	vec4 state = texture(swe_surface, river_swe_uv(point));
	return mix(original, state.z, weight);
}
