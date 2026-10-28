shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
#include "res://shaders/river/river_swe.gdshaderinc"

uniform sampler2D flow_map : filter_linear, repeat_disable;
uniform sampler2D bed_height_texture : filter_linear, repeat_disable;
uniform sampler2D riverbed_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_map : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D micro_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_filaments : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_black;
uniform sampler2D foam_bubbles : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_black;
uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D reflection_texture : filter_linear, repeat_disable;
uniform sampler2D reflection_texture_1 : filter_linear, repeat_disable;
uniform sampler2D reflection_texture_2 : filter_linear, repeat_disable;
uniform sampler2D reflection_texture_3 : filter_linear, repeat_disable;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform mat4 reflection_view;
uniform mat4 reflection_projection;
uniform mat4 reflection_view_1;
uniform mat4 reflection_projection_1;
uniform mat4 reflection_view_2;
uniform mat4 reflection_projection_2;
uniform mat4 reflection_view_3;
uniform mat4 reflection_projection_3;
uniform int reflection_planes = 1;
uniform vec4 reflection_plane = vec4(0.0, 1.0, 0.0, 0.0);
uniform vec2 reflection_levels_m = vec2(0.0);
uniform vec4 terrace_heights_m = vec4(0.0);
uniform float surface_slope = 0.0;
uniform float surface_detail = 0.0;
uniform vec2 domain_m = vec2(1.0);
uniform vec2 domain_origin_m = vec2(0.0);
uniform float water_level_m = 0.06;
uniform float flow_distance_m = 0.0;
uniform float simulation_time_s = 0.0;
uniform vec2 foam_reference_flow = vec2(0.0);
uniform float speed_m_s = 0.85;
uniform float ripple_height_m = 0.035;
uniform float clarity = 0.82;
uniform float roughness = 0.085;
uniform float whitewater_strength = 0.12;
uniform float foam_amount = 0.65;
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);
uniform vec3 deep_tint : source_color = vec3(0.035, 0.19, 0.17);
uniform vec2 deep_tint_depth_m = vec2(0.0);
uniform bool lit_body = false;
uniform float body_min_thickness_m = 0.0;
uniform float shore_fade_depth_m = 0.0;
uniform float shore_soft_thickness_m = 0.0;
uniform float domain_edge_fade_m = 0.0;
uniform bool guided_coverage = false;
uniform bool reflection_enabled = true;
uniform bool foam_enabled = true;
uniform bool foam_detail = true;
uniform vec4 geometry_region_m = vec4(-6.0, -7.0, 16.0, 24.0);
// Per solver cell, the surface height at its corners (river_swe.comp); infinite where no surface is drawn.
uniform sampler2D swe_corners : filter_nearest, repeat_disable, hint_default_black;
// Cells across the domain when the mesh is one quad of four vertices per solver cell, zero for a shared-vertex grid.
uniform ivec2 cell_grid = ivec2(0);
uniform float cell_size_m = 0.125;

const vec2 RUN_UP_SLOPE = vec2(0.7, 1.2);
const vec2 PLANE_REACH_M = vec2(0.6, 1.5);
const float SPLASH_RADIUS_M = 0.35;
const float LANDING_FOAM_M_S = 0.3;
// Corner heights of two cells this close are one surface: river_swe.comp gives every cell of a surface the same value.
const float SHARED_CORNER_M = 1.0e-4;
// A cell surface runs on into the rock it meets, which cuts it at the shore; it fades over this thickness of water.
const float SHORE_SOFT_M = 0.02;

varying vec3 world_position;
varying vec3 surface_normal;

vec2 domain_uv(vec2 point) {
	return (point - domain_origin_m) / domain_m + 0.5;
}

float live_share(vec2 point) {
	float weight = river_swe_weight(point);
	if (guided_coverage && weight > 0.0) {
		vec2 guided = texture(bed_height_texture, domain_uv(point)).rg;
		float live_depth = texture(swe_surface, river_swe_uv(point)).w;
		weight *= 1.0 - step(0.015, guided.y - guided.x) * (1.0 - smoothstep(0.004, 0.015, live_depth));
	}
	return weight;
}

float basin_height(vec2 point) {
	float original = texture(bed_height_texture, domain_uv(point)).g;
	float weight = live_share(point);
	return weight > 0.0 ? mix(original, texture(swe_surface, river_swe_uv(point)).z, weight) : original;
}

// Where spilled water lands, as a depth rate in m/s, spread over the splash around the landing cells.
float spill_landing(vec2 point) {
	float total = 0.0;
	for (int i = 0; i < 5; i++) {
		vec2 offset = i == 0 ? vec2(0.0) : vec2(float(i == 1) - float(i == 2), float(i == 3) - float(i == 4)) * SPLASH_RADIUS_M;
		total += texture(swe_spill, river_swe_uv(point + offset)).g;
	}
	return total / 5.0;
}

vec2 flow_uv(vec2 position, vec2 flow, float phase) {
	return position - flow * phase * 1.5 + vec2(0.0, flow_distance_m * 0.18);
}

float moving_noise(vec2 position, vec2 flow, float scale, float mip) {
	float phase_offset = textureLod(turbulence_texture, position * 0.009, 2.0).r;
	float phase = fract(flow_distance_m / 1.5 + phase_offset);
	float second = fract(phase + 0.5);
	float first_noise = textureLod(turbulence_texture, flow_uv(position, flow, phase) * scale, mip).r;
	float second_noise = textureLod(turbulence_texture, flow_uv(position, flow, second) * scale, mip).r;
	return mix(first_noise, second_noise, abs(phase * 2.0 - 1.0));
}

float ripple(vec2 position, vec2 flow, float activity) {
	vec2 edge = min(position - geometry_region_m.xy, geometry_region_m.xy + geometry_region_m.zw - position);
	float geometry_lod = 1.0 - smoothstep(2.0, 12.0, -min(edge.x, edge.y));
	float large = moving_noise(position, flow, 0.035, 2.0) * 2.0 - 1.0;
	float small = moving_noise(position + vec2(11.0, 29.0), flow, mix(0.065, 0.16, surface_detail), mix(2.0, 0.5, surface_detail)) * 2.0 - 1.0;
	float energetic = smoothstep(0.04, 0.35, activity) * whitewater_strength;
	return geometry_lod * ripple_height_m * (large * 0.6 + small * (0.22 + energetic * mix(1.3, 2.4, surface_detail)));
}

vec3 foam_normal(float pattern) {
	vec3 raised_x = dFdx(world_position) + vec3(0.0, dFdx(pattern) * 0.005, 0.0);
	vec3 raised_y = dFdy(world_position) + vec3(0.0, dFdy(pattern) * 0.005, 0.0);
	vec3 normal = normalize(cross(raised_x, raised_y));
	return normal * sign(normal.y);
}

float foam_selection(vec2 point, float weight) {
	vec2 cell = floor(point * 12.5);
	vec2 local = fract(point * 12.5);
	vec4 selection = mix(vec4(0.05), vec4(0.95), fract(sin(vec4(
		dot(cell, vec2(127.1, 311.7)),
		dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7)),
		dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7)),
		dot(cell + vec2(1.0, 1.0), vec2(127.1, 311.7)))) * 43758.5453));
	vec4 weights = smoothstep(selection - vec4(0.04), selection + vec4(0.04), vec4(weight));
	return mix(mix(weights.x, weights.y, local.x), mix(weights.z, weights.w, local.x), local.y);
}

vec4 planar_sample(int index, vec3 position) {
	vec4 reflected;
	if (index == 1) {
		reflected = reflection_projection_1 * reflection_view_1 * vec4(position, 1.0);
	} else if (index == 2) {
		reflected = reflection_projection_2 * reflection_view_2 * vec4(position, 1.0);
	} else if (index == 3) {
		reflected = reflection_projection_3 * reflection_view_3 * vec4(position, 1.0);
	} else {
		reflected = reflection_projection * reflection_view * vec4(position, 1.0);
	}
	vec2 uv = reflected.xy / max(reflected.w, 0.001) * 0.5 + 0.5;
	uv.y = 1.0 - uv.y;
	vec2 border = smoothstep(vec2(0.0), vec2(0.025), uv) * (1.0 - smoothstep(vec2(0.975), vec2(1.0), uv));
	float valid = border.x * border.y * step(0.0, reflected.w);
	uv = clamp(uv, vec2(0.001), vec2(0.999));
	vec3 color;
	if (index == 1) { color = texture(reflection_texture_1, uv).rgb; }
	else if (index == 2) { color = texture(reflection_texture_2, uv).rgb; }
	else if (index == 3) { color = texture(reflection_texture_3, uv).rgb; }
	else { color = texture(reflection_texture, uv).rgb; }
	return vec4(color, valid);
}

// v[i] with a runtime i compiles to OpVectorExtractDynamic, which Godot's SPIR-V pass rejects at every compile.
float component(vec4 v, int i) {
	return i == 0 ? v.x : (i == 1 ? v.y : (i == 2 ? v.z : v.w));
}

// A quad corner of a cell surface: its height, its slope along x and z from the neighbours sharing that corner, and
// whether all four cells around it share it (false on a lip, a front or a wall, where a side may hang from it).
// False where the cell draws no surface.
bool cell_corner(vec2 centre, int corner, out float level, out vec2 slope, out bool inner) {
	ivec2 size = textureSize(swe_corners, 0);
	ivec2 cell = clamp(ivec2(floor(river_swe_uv(centre) * vec2(size))), ivec2(0), size - 1);
	vec4 own = texelFetch(swe_corners, cell, 0);
	level = component(own, corner);
	slope = vec2(0.0);
	inner = false;
	if (isinf(level)) { return false; }
	ivec2 side = ivec2(corner & 1, corner >> 1) * 2 - 1;
	ivec2 cell_x = clamp(cell + ivec2(side.x, 0), ivec2(0), size - 1);
	ivec2 cell_z = clamp(cell + ivec2(0, side.y), ivec2(0), size - 1);
	vec4 across_x = texelFetch(swe_corners, cell_x, 0);
	vec4 across_z = texelFetch(swe_corners, cell_z, 0);
	float across_d = component(texelFetch(swe_corners, clamp(cell + side, ivec2(0), size - 1), 0), corner ^ 3);
	bool meets_x = abs(component(across_x, corner ^ 1) - level) < SHARED_CORNER_M;
	bool meets_z = abs(component(across_z, corner ^ 2) - level) < SHARED_CORNER_M;
	inner = meets_x && meets_z && abs(across_d - level) < SHARED_CORNER_M;
	// Centred where a wet neighbour shares the corner; one-sided against another surface or a dry cell carrying this one.
	bool shared_x = meets_x && texelFetch(swe_surface, cell_x, 0).w > 0.004;
	bool shared_z = meets_z && texelFetch(swe_surface, cell_z, 0).w > 0.004;
	float back_x = component(own, corner ^ 1);
	float back_z = component(own, corner ^ 2);
	float rise_x = shared_x ? (component(across_x, corner) - back_x) * 0.5 : level - back_x;
	float rise_z = shared_z ? (component(across_z, corner) - back_z) * 0.5 : level - back_z;
	slope = vec2(rise_x, rise_z) * vec2(side) * vec2(size) / swe_region_m.zw;
	return true;
}

void vertex() {
	vec2 point = VERTEX.xz;
	vec2 centre = point;
	int corner = 0;
	if (cell_grid.x > 0) {
		// Four vertices per cell, placed from their index: a lip or a wall splits the surface along a cell edge.
		// A corner shared by several quads gets the same integer index and so the same position in each.
		int quad = VERTEX_ID / 4;
		corner = VERTEX_ID % 4;
		ivec2 cell = ivec2(quad % cell_grid.x, quad / cell_grid.x);
		vec2 origin = domain_origin_m - domain_m * 0.5;
		point = origin + vec2(cell + ivec2(corner & 1, corner >> 1)) * cell_size_m;
		centre = origin + (vec2(cell) + 0.5) * cell_size_m;
	}
	vec4 field = texture(flow_map, domain_uv(point));
	float weight = live_share(point);
	vec4 live = texture(swe_surface, river_swe_uv(point));
	field.rg = mix(field.rg, live.xy / max(speed_m_s, 0.1), weight);
	float level = 0.0;
	vec2 slope = vec2(0.0);
	bool inner = true;
	bool cell_live = cell_grid.x > 0 && cell_corner(centre, corner, level, slope, inner);
	// The edge of a cell surface stays at its level, as the side hanging from it (river_water_skirt.gdshader) does.
	float ripple_scale = cell_live && !inner ? 0.0 : 1.0;
	if (cell_grid.x > 0 && !cell_live && live_share(centre) > 0.0) {
		// No surface in this cell: its four vertices meet at its centre.
		VERTEX = vec3(centre.x, 0.0, centre.y);
		surface_normal = vec3(0.0, 1.0, 0.0);
	} else {
		vec2 right = point + vec2(0.08, 0.0);
		vec2 down = point + vec2(0.0, 0.08);
		float h = cell_live ? mix(texture(bed_height_texture, domain_uv(point)).g, level, weight) : basin_height(point);
		float right_h = cell_live ? mix(texture(bed_height_texture, domain_uv(right)).g, level + slope.x * 0.08, live_share(right)) : basin_height(right);
		float down_h = cell_live ? mix(texture(bed_height_texture, domain_uv(down)).g, level + slope.y * 0.08, live_share(down)) : basin_height(down);
		h += ripple(point, field.rg, field.b) * field.a * mix(1.0, 0.25, weight) * ripple_scale;
		VERTEX = vec3(point.x, h, point.y);
		float dx = (right_h + ripple(right, field.rg, field.b) * field.a * mix(1.0, 0.25, live_share(right)) * ripple_scale - h) / 0.08;
		float dz = (down_h + ripple(down, field.rg, field.b) * field.a * mix(1.0, 0.25, live_share(down)) * ripple_scale - h) / 0.08;
		surface_normal = normalize(vec3(-dx, 1.0, -dz));
	}
	world_position = VERTEX;
}

void fragment() {
	vec2 sample_point = world_position.xz;
	vec2 field_uv = domain_uv(sample_point);
	vec4 field = texture(flow_map, field_uv);
	float live_weight = live_share(sample_point);
	vec2 live_uv = river_swe_uv(sample_point);
	vec4 live = texture(swe_surface, live_uv);
	float wet_coverage = 1.0;
	vec3 guided_bed = texture(bed_height_texture, field_uv).rgb;
	if (shore_fade_depth_m > 0.0) {
		wet_coverage = mix(1.0, smoothstep(0.0, shore_fade_depth_m, guided_bed.y - guided_bed.x), guided_bed.z);
	}
	if (swe_enabled && cell_grid.x == 0) {
		vec2 bed = guided_bed.xy;
		bed.x = texture(bed_height_texture, domain_uv(world_position.xz)).r;
		float live_depth = min(live.w, max(world_position.y - texture(swe_terrain, river_swe_uv(world_position.xz)).r, 0.0));
		float depth = mix(max(bed.y - bed.x, 0.0), live_depth, live_weight);
		float edge_width = max(fwidth(depth), 0.002);
		wet_coverage = mix(wet_coverage, smoothstep(0.015 - edge_width, 0.015 + edge_width, depth), live_weight);
		// Past this triangle slope the heightfield climbs a rock or steps down a crest: what is behind shows instead.
		vec3 facet = cross(dFdx(world_position), dFdy(world_position));
		float slope = length(facet.xz) / max(abs(facet.y), 1.0e-6);
		wet_coverage *= 1.0 - smoothstep(RUN_UP_SLOPE.x, RUN_UP_SLOPE.y, slope) * live_weight;
	}
	bool cell_shore = swe_enabled && cell_grid.x > 0;
	if (!cell_shore && wet_coverage <= 0.0) { discard; }
	vec2 flow_velocity = mix(field.rg * speed_m_s, live.xy, live_weight);
	field.rg = mix(field.rg, live.xy / max(speed_m_s, 0.1), live_weight);
	field.b = mix(field.b, texture(swe_foam, live_uv).b, live_weight);
	float fall_impact = swe_spill_enabled ? smoothstep(0.0, LANDING_FOAM_M_S, spill_landing(world_position.xz)) * live_weight : 0.0;
	field.b = max(field.b, fall_impact);
	field.a = mix(field.a, smoothstep(0.004, 0.04, live.w), live_weight);
	float phase_offset = texture(turbulence_texture, world_position.xz * 0.009).r;
	float phase = fract(flow_distance_m / 1.5 + phase_offset);
	float phase2 = fract(phase + 0.5);
	vec2 p = world_position.xz;
	vec2 uv1 = flow_uv(p, field.rg, phase) * 0.7;
	vec2 uv2 = flow_uv(p, field.rg, phase2) * 0.7;
	vec2 detail = mix(texture(micro_normal, uv1).rg, texture(micro_normal, uv2).rg, abs(phase * 2.0 - 1.0)) * 2.0 - 1.0;
	float fine = 0.04 + ripple_height_m * 0.3;
	vec3 normal_world = normalize(surface_normal + vec3(detail.x, 0.0, detail.y) * fine);
	if (surface_detail > 0.0) {
		vec2 coarse_uv1 = flow_uv(p, field.rg, phase) * 0.17;
		vec2 coarse_uv2 = flow_uv(p, field.rg, phase2) * 0.17;
		vec3 coarse = mix(texture(micro_normal, coarse_uv1).rgb, texture(micro_normal, coarse_uv2).rgb,
			abs(phase * 2.0 - 1.0)) * 2.0 - 1.0;
		mat2 rotation = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
		vec2 crossed_uv1 = rotation * flow_uv(p, field.rg, phase) * 0.43 + vec2(0.32, 0.71);
		vec2 crossed_uv2 = rotation * flow_uv(p, field.rg, phase2) * 0.43 + vec2(0.32, 0.71);
		vec3 crossed = mix(texture(micro_normal, crossed_uv1).rgb, texture(micro_normal, crossed_uv2).rgb,
			abs(phase * 2.0 - 1.0)) * 2.0 - 1.0;
		vec2 slopes = coarse.xy / max(coarse.z, 0.4) + crossed.xy / max(crossed.z, 0.4) * 0.45;
		float strength = mix(0.025, 0.28, smoothstep(0.005, 0.12, ripple_height_m));
		normal_world = normalize(normal_world + vec3(slopes.x, 0.0, slopes.y) * strength * surface_detail);
	}
	if (fall_impact > 0.0) {
		float churn_t = simulation_time_s * 0.45;
		vec2 churn = vec2(texture(turbulence_texture, p * 0.8 + vec2(churn_t, -churn_t * 0.6)).r,
			texture(turbulence_texture, p * 1.5 + vec2(0.37 - churn_t * 0.7, churn_t)).r) - 0.5;
		normal_world = normalize(normal_world + vec3(churn.x, 0.0, churn.y) * fall_impact * 1.4);
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_texture, SCREEN_UV).r, 1.0);
	behind.xyz /= behind.w;
	float behind_m = max(-behind.z + VERTEX.z, 0.0);
	if (cell_shore) {
		// Solver depth stays positive across a lip, where both cells are wet: it only fades films and edges over dry cells.
		float edge_width = max(fwidth(live.w), 0.002);
		float film = smoothstep(0.015 - edge_width, 0.015 + edge_width, live.w);
		wet_coverage = mix(wet_coverage, film * smoothstep(0.0, SHORE_SOFT_M, behind_m), live_weight);
		if (wet_coverage <= 0.0) { discard; }
	}
	float thickness = max(behind_m, body_min_thickness_m * field.a);
	// Seen from below, the straight ray climbs out of the water at once: the refracted one runs down to the bed.
	vec3 view_ray = -normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	if (view_ray.y > 0.0) {
		float water_m = max(world_position.y - mix(guided_bed.x, texture(swe_terrain, live_uv).r, live_weight), 0.0);
		vec3 refracted = refract(view_ray, faceforward(normal_world, view_ray, normal_world), 0.75);
		thickness = min(thickness, water_m / max(-refracted.y, 0.1));
	}
	vec2 edge_fade = smoothstep(vec2(0.0), vec2(0.04), SCREEN_UV) * (1.0 - smoothstep(vec2(0.96), vec2(1.0), SCREEN_UV));
	vec2 refracted_uv = SCREEN_UV + NORMAL.xy * 0.015 * smoothstep(0.0, 0.3, thickness) * edge_fade.x * edge_fade.y;
	vec4 refracted_depth = INV_PROJECTION_MATRIX * vec4(refracted_uv * 2.0 - 1.0, texture(depth_texture, refracted_uv).r, 1.0);
	refracted_depth.xyz /= refracted_depth.w;
	if (refracted_depth.z > VERTEX.z - 0.02) { refracted_uv = SCREEN_UV; }
	vec3 transmission = textureLod(screen_texture, clamp(refracted_uv, vec2(0.001), vec2(0.999)), 0.0).rgb;
	if (thickness < 0.002) {
		float bed = mix(texture(bed_height_texture, field_uv).r, texture(swe_terrain, live_uv).r, live_weight);
		float bed_depth = max(world_position.y - bed, 0.0);
		vec3 world_view = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		thickness = bed_depth / max(abs(world_view.y), 0.2);
		if (live_weight <= 0.0) { transmission = texture(riverbed_albedo, world_position.xz * 0.48).rgb * 0.7; }
	}
	float absorption = mix(mix(3.8, 0.32, clarity), mix(3.8, 0.08, pow(clarity, 0.6)), surface_detail);
	vec3 transmittance = exp(-vec3(absorption * 1.25, absorption * 0.72, absorption * 0.63) * thickness);
	vec3 body_tint = deep_tint_depth_m.y > deep_tint_depth_m.x
		? mix(deep_color, deep_tint, smoothstep(deep_tint_depth_m.x, deep_tint_depth_m.y, max(guided_bed.y - guided_bed.x, 0.0)))
		: deep_color;
	vec3 body = transmission * transmittance + body_tint * (vec3(1.0) - transmittance);
	body = mix(body, vec3(0.32, 0.4, 0.41), fall_impact * 0.85);
	float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 5.0);
	vec3 reflected_point = world_position + vec3(normal_world.x, 0.0, normal_world.z)
		* mix(0.12, 1.5, surface_detail) * smoothstep(0.0, 12.0, length(VERTEX));
	vec4 reflection = vec4(0.0);
	if (reflection_enabled) {
		reflection = planar_sample(0, reflected_point);
		// One plane mirrors only water near it: a pool a fall away would show a wrong level and what lies under its water.
		if (reflection_planes == 1 && swe_spill_enabled) {
			float off_plane = abs(dot(world_position, reflection_plane.xyz) - reflection_plane.w);
			reflection.a *= 1.0 - smoothstep(PLANE_REACH_M.x, PLANE_REACH_M.y, off_plane);
		}
		if (reflection_planes == 2) {
			// A pool plane mirrors only for a viewer above it; seen from below, its water reflects the sky.
			vec2 seen = step(reflection_levels_m, vec2(CAMERA_POSITION_WORLD.y));
			reflection.a *= seen.x;
			float upper = smoothstep(0.25, 0.75, (world_position.y - reflection_levels_m.x) / max(reflection_levels_m.y - reflection_levels_m.x, 0.001));
			if (upper > 0.001) { reflection = mix(reflection, planar_sample(1, reflected_point) * vec4(1.0, 1.0, 1.0, seen.y), upper); }
		}
		if (reflection_planes == 4) {
			float terrace = texture(bed_height_texture, field_uv).g - water_level_m - p.y * surface_slope;
			vec3 weights = clamp((vec3(terrace) - terrace_heights_m.xyz)
				/ max(terrace_heights_m.yzw - terrace_heights_m.xyz, vec3(0.001)), vec3(0.0), vec3(1.0));
			reflection *= (1.0 - weights.x);
			if (weights.x - weights.y > 0.001) { reflection += planar_sample(1, reflected_point) * (weights.x - weights.y); }
			if (weights.y - weights.z > 0.001) { reflection += planar_sample(2, reflected_point) * (weights.y - weights.z); }
			if (weights.z > 0.001) { reflection += planar_sample(3, reflected_point) * weights.z; }
		}
	}
	float reflection_weight = reflection.a * (1.0 - smoothstep(0.0, 0.3, fall_impact));
	vec3 reflected_color = reflection.rgb;
	vec3 sky = vec3(0.27, 0.38, 0.48);
	reflected_color = mix(sky, reflected_color, reflection_weight);
	vec2 foam_history = mix(texture(foam_map, field_uv).rg, texture(swe_foam, live_uv).rg, live_weight);
	if (fall_impact > 0.0) {
		float impact = fall_impact * foam_amount;
		foam_history = max(foam_history, vec2(impact * 0.9, impact));
	}
	float coverage = foam_history.r;
	float breakup = moving_noise(p + vec2(11.0, 29.0), field.rg, 0.09, 0.0);
	float foam = smoothstep(0.18, 0.8, coverage) * smoothstep(0.3, 0.62, breakup);
	float turbulent = whitewater_strength * smoothstep(0.12, 0.65, field.b);
	foam = max(foam, turbulent * smoothstep(0.4, 0.65, breakup) * 0.55 * foam_amount);
	if (foam_detail) {
		float foam_phase = fract(simulation_time_s / 1.5);
		float foam_phase2 = fract(foam_phase + 0.5);
		vec2 foam_position = p - foam_reference_flow * flow_distance_m;
		vec2 foam_relative_velocity = flow_velocity - foam_reference_flow * speed_m_s;
		float foam_offset = 0.5 * (1.0 - live_weight);
		vec2 foam_uv1 = (foam_position - foam_relative_velocity * (foam_phase - foam_offset) * 1.5) * vec2(0.28, 0.2);
		vec2 foam_uv2 = (foam_position - foam_relative_velocity * (foam_phase2 - foam_offset) * 1.5) * vec2(0.28, 0.2);
		float fresh = foam_history.g;
		float fresh_weight = smoothstep(0.1, 0.55, fresh);
		float pattern1 = mix(texture(foam_filaments, foam_uv1).r, texture(foam_bubbles, foam_uv1 * 1.8).r, fresh_weight);
		float pattern2 = mix(texture(foam_filaments, foam_uv2).r, texture(foam_bubbles, foam_uv2 * 1.8).r, fresh_weight);
		vec2 selection_point = foam_position - foam_relative_velocity * (foam_phase2 - foam_offset) * 1.5;
		float phase_weight = abs(foam_phase * 2.0 - 1.0);
		float second_weight = foam_selection(selection_point, phase_weight);
		float density = max(coverage, turbulent * 0.4 * foam_amount);
		float dense_threshold = swe_spill_enabled ? mix(0.58, 0.5, fresh_weight) : mix(0.36, 0.24, fresh_weight);
		float threshold = mix(0.84, dense_threshold, smoothstep(0.04, 0.9, density));
		float aa1 = max(fwidth(pattern1) * 1.1, 0.015);
		float aa2 = max(fwidth(pattern2) * 1.1, 0.015);
		float mask1 = smoothstep(threshold - aa1, threshold + aa1, pattern1);
		float mask2 = smoothstep(threshold - aa2, threshold + aa2, pattern2);
		foam = min(mix(mask1, mask2, second_weight) * smoothstep(0.025, 0.22, density), 0.9);
		if (surface_detail > 0.0) {
			vec3 froth_normal = normalize(mix(foam_normal(pattern1), foam_normal(pattern2), second_weight));
			normal_world = normalize(mix(normal_world, froth_normal, foam * surface_detail * 0.65));
			NORMAL = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
		}
	}
	foam *= step(0.001, foam_amount) * float(foam_enabled);
	foam = clamp(foam, 0.0, 0.9);
	ALBEDO = vec3(0.82, 0.87, 0.83) * foam;
	EMISSION = mix(mix(body, reflected_color, fresnel), body * (1.0 - fresnel), surface_detail) * (1.0 - foam);
	if (lit_body) {
		ALBEDO = mix(body_tint * (vec3(1.0) - transmittance), vec3(0.82, 0.87, 0.83), foam);
		EMISSION = transmission * transmittance * (1.0 - fresnel) * (1.0 - foam);
	}
	RADIANCE = vec4(reflection.rgb, reflection_weight * surface_detail * (1.0 - foam));
	vec3 nx = dFdx(normal_world);
	vec3 ny = dFdy(normal_world);
	float variance = min(dot(nx, nx) + dot(ny, ny), 1.0);
	float polished = clamp(roughness * 0.28, 0.025, 0.07);
	float water_roughness = mix(roughness, sqrt(polished * polished + variance * 0.08), surface_detail);
	ROUGHNESS = mix(water_roughness, 0.72, foam);
	SPECULAR = mix(mix(0.18, 0.35, surface_detail), 0.12, foam);
	vec2 border = min(domain_uv(world_position.xz), vec2(1.0) - domain_uv(world_position.xz)) * domain_m;
	float domain_fade = domain_edge_fade_m > 0.0 ? smoothstep(0.0, domain_edge_fade_m, min(border.x, border.y)) : 1.0;
	float soft_shore = shore_soft_thickness_m > 0.0 ? mix(1.0, smoothstep(0.0, shore_soft_thickness_m, behind_m), guided_bed.z) : 1.0;
	ALPHA = wet_coverage * domain_fade * soft_shore;
}
