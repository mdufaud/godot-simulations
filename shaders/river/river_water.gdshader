shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
#include "res://shaders/river/river_swe.gdshaderinc"

uniform sampler2D flow_map : filter_linear, repeat_disable;
uniform sampler2D bed_height_texture : filter_linear, repeat_disable;
uniform sampler2D riverbed_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_map : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D micro_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_filaments : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_bubbles : filter_linear_mipmap_anisotropic, repeat_enable;
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
uniform bool waterfall_enabled = false;
uniform vec4 waterfall_geometry = vec4(6.0, 6.0, 4.0, 0.0);
uniform vec3 waterfall_grid;
uniform sampler2D waterfall_surface : filter_nearest, repeat_disable;
uniform sampler2D waterfall_boundary : filter_nearest, repeat_disable;
uniform vec4 terrace_heights_m = vec4(0.0);
uniform float surface_slope = 0.0;
uniform float surface_detail = 0.0;
uniform vec2 domain_m = vec2(1.0);
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
uniform bool reflection_enabled = true;
uniform bool foam_enabled = true;
uniform bool foam_detail = true;
uniform vec4 geometry_region_m = vec4(-6.0, -7.0, 16.0, 24.0);

varying vec3 world_position;
varying vec3 surface_normal;

float waterfall_receiver(float x) {
	if (waterfall_clock_enabled) {
		vec4 boundary = textureLod(waterfall_boundary, vec2(clamp(x / waterfall_geometry.x + 0.5, 0.0, 1.0), 0.5), 0.0);
		if (boundary.y > 0.0 && waterfall_geometry.w > 0.0) return boundary.z;
	}
	return waterfall_geometry.z - max(waterfall_geometry.w * max((waterfall_geometry.y - 0.65 - water_level_m) / waterfall_geometry.y, 0.0), 0.125);
}

float waterfall_wet_end() {
	return waterfall_geometry.z - max(waterfall_geometry.w * max((waterfall_geometry.y - 0.65 - water_level_m) / waterfall_geometry.y, 0.0), 0.125);
}

float waterfall_pool_end(float x) {
	return waterfall_geometry.z - 0.05;
}

float waterfall_source_active(float x) {
	if (!waterfall_clock_enabled) return step(0.001, speed_m_s);
	vec4 clock = texture(waterfall_clock, vec2(0.5));
	float row = waterfall_geometry.w > 0.0 ? 0.5 / waterfall_grid.y : (clock.g + 0.5) / waterfall_grid.z;
	return step(0.0001, texture(waterfall_surface,
		vec2(clamp(x / waterfall_geometry.x + 0.5, 0.0, 1.0), row)).w) * step(0.001, clock.r);
}

float waterfall_impact(vec2 point) {
	float impact_z = waterfall_geometry.z - (waterfall_geometry.w > 0.0
		? waterfall_geometry.w * max((waterfall_geometry.y - 0.65 - water_level_m) / waterfall_geometry.y, 0.0)
		: speed_m_s * sqrt(2.0 * waterfall_geometry.y / 9.81));
	if (waterfall_clock_enabled) {
		vec4 boundary = textureLod(waterfall_boundary, vec2(clamp(point.x / waterfall_geometry.x + 0.5, 0.0, 1.0), 0.5), 0.0);
		if (boundary.y > 0.0) impact_z = boundary.z;
	}
	float downstream = max(impact_z - point.y, 0.0);
	float band = exp(-pow((point.y - impact_z) / 0.65, 2.0)) + 0.5 * exp(-downstream / 2.5) * step(point.y, impact_z);
	return min(band, 1.0) * waterfall_source_active(point.x)
		* (1.0 - smoothstep(waterfall_geometry.x * 0.5 - 0.3, waterfall_geometry.x * 0.5 + 0.2, abs(point.x)));
}

float basin_height(vec2 point) {
	if (waterfall_enabled) {
		bool upper = point.y >= waterfall_geometry.z - 0.0001;
		float end_z = waterfall_wet_end();
		point.y = upper ? max(point.y, waterfall_geometry.z + 0.125)
			: min(point.y, end_z);
		return river_swe_height(point, water_level_m + (upper ? waterfall_geometry.y : 0.0));
	}
	return river_swe_height(point, texture(bed_height_texture, point / domain_m + 0.5).g);
}

vec2 flow_uv(vec2 position, vec2 flow, float phase) {
	float distance_m = waterfall_clock_enabled ? river_render_time(simulation_time_s) * speed_m_s : flow_distance_m;
	return position - flow * phase * 1.5 + vec2(0.0, distance_m * 0.18);
}

float moving_noise(vec2 position, vec2 flow, float scale, float mip) {
	float phase_offset = textureLod(turbulence_texture, position * 0.009, 2.0).r;
	float phase = fract((waterfall_clock_enabled ? river_render_time(simulation_time_s) * speed_m_s : flow_distance_m) / 1.5 + phase_offset);
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

void vertex() {
	vec2 point = VERTEX.xz;
	if (waterfall_enabled && UV2.x < 0.5) point.y = mix(-domain_m.y * 0.5, waterfall_pool_end(point.x), UV2.y);
	VERTEX.z = point.y;
	vec4 field = texture(flow_map, point / domain_m + 0.5);
	float weight = river_swe_weight(point);
	vec4 live = texture(swe_surface, river_swe_uv(point));
	field.rg = mix(field.rg, live.xy / max(speed_m_s, 0.1), weight);
	float h = basin_height(point)
		+ ripple(point, field.rg, field.b) * field.a * mix(1.0, 0.25, weight);
	VERTEX.y = h;
	if (waterfall_enabled && !swe_enabled) VERTEX.y = water_level_m + (point.y >= waterfall_geometry.z ? waterfall_geometry.y : 0.0);
	vec2 right = point + vec2(0.08, 0.0);
	vec2 down = point + vec2(0.0, 0.08);
	float dx = (basin_height(right)
		+ ripple(right, field.rg, field.b) * field.a * mix(1.0, 0.25, river_swe_weight(right)) - h) / 0.08;
	float dz = (basin_height(down)
		+ ripple(down, field.rg, field.b) * field.a * mix(1.0, 0.25, river_swe_weight(down)) - h) / 0.08;
	surface_normal = normalize(vec3(-dx, 1.0, -dz));
	if (waterfall_enabled && !swe_enabled) surface_normal = vec3(0.0, 1.0, 0.0);
	world_position = VERTEX;
}

void fragment() {
	if (waterfall_enabled && abs(world_position.x) < waterfall_geometry.x * 0.5 + 0.01
		&& world_position.z < waterfall_geometry.z + 0.001 && world_position.z > waterfall_pool_end(world_position.x) - 0.001) { discard; }
	vec2 sample_point = world_position.xz;
	if (waterfall_enabled && sample_point.y < waterfall_geometry.z) sample_point.y = min(sample_point.y, waterfall_wet_end());
	vec2 field_uv = sample_point / domain_m + 0.5;
	vec4 field = texture(flow_map, field_uv);
	float live_weight = river_swe_weight(sample_point);
	vec2 live_uv = river_swe_uv(sample_point);
	vec4 live = texture(swe_surface, live_uv);
	float wet_coverage = 1.0;
	if (swe_enabled) {
		vec2 bed = texture(bed_height_texture, field_uv).rg;
		bed.x = texture(bed_height_texture, world_position.xz / domain_m + 0.5).r;
		float live_depth = min(live.w, max(world_position.y - texture(swe_terrain, river_swe_uv(world_position.xz)).r, 0.0));
		float depth = mix(max(bed.y - bed.x, 0.0), live_depth, live_weight);
		float edge_width = max(fwidth(depth), 0.002);
		wet_coverage = mix(1.0, smoothstep(0.015 - edge_width, 0.015 + edge_width, depth), live_weight);
		if (wet_coverage <= 0.0) { discard; }
	}
	vec2 flow_velocity = mix(field.rg * speed_m_s, live.xy, live_weight);
	field.rg = mix(field.rg, live.xy / max(speed_m_s, 0.1), live_weight);
	field.b = mix(field.b, texture(swe_foam, live_uv).b, live_weight);
	float fall_impact = waterfall_enabled && world_position.z < waterfall_geometry.z ? waterfall_impact(world_position.xz) : 0.0;
	field.b = max(field.b, fall_impact);
	field.a = mix(field.a, smoothstep(0.004, 0.04, live.w), live_weight);
	float phase_offset = texture(turbulence_texture, world_position.xz * 0.009).r;
	float phase = fract((waterfall_clock_enabled ? river_render_time(simulation_time_s) * speed_m_s : flow_distance_m) / 1.5 + phase_offset);
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
	NORMAL = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_texture, SCREEN_UV).r, 1.0);
	behind.xyz /= behind.w;
	float thickness = max(-behind.z + VERTEX.z, 0.0);
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
	vec3 body = transmission * transmittance + deep_color * (vec3(1.0) - transmittance);
	body = mix(body, vec3(0.32, 0.4, 0.41), fall_impact * 0.85);
	float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 5.0);
	vec3 reflected_point = world_position + vec3(normal_world.x, 0.0, normal_world.z)
		* mix(0.12, 1.5, surface_detail) * smoothstep(0.0, 12.0, length(VERTEX));
	vec4 reflection = vec4(0.0);
	if (reflection_enabled) {
		if (!waterfall_enabled || reflection_planes > 1 || world_position.z < waterfall_geometry.z) {
			reflection = planar_sample(0, reflected_point);
		}
		if (reflection_planes == 2 && world_position.z > waterfall_geometry.z) {
			reflection = planar_sample(1, reflected_point);
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
	float reflection_weight = reflection.a;
	vec3 reflected_color = reflection.rgb;
	vec3 sky = vec3(0.27, 0.38, 0.48);
	reflected_color = mix(sky, reflected_color, reflection_weight);
	vec2 foam_history = mix(texture(foam_map, field_uv).rg, texture(swe_foam, live_uv).rg, live_weight);
	if (fall_impact > 0.0) {
		float impact = fall_impact * foam_amount;
		foam_history = max(foam_history, vec2(impact * 0.9, impact));
	}
	if (waterfall_enabled && world_position.z >= waterfall_geometry.z) {
		float source_active = waterfall_source_active(world_position.x);
		float lip = (1.0 - smoothstep(0.05, 0.4, world_position.z - waterfall_geometry.z)) * 0.6
			* (1.0 - smoothstep(waterfall_geometry.x * 0.5 - 0.1, waterfall_geometry.x * 0.5 + 0.4, abs(world_position.x)))
			* source_active * sqrt(max(foam_amount, 0.0));
		foam_history = max(foam_history, vec2(lip * 0.85, lip));
	}
	float coverage = foam_history.r;
	float breakup = moving_noise(p + vec2(11.0, 29.0), field.rg, 0.09, 0.0);
	float foam = smoothstep(0.18, 0.8, coverage) * smoothstep(0.3, 0.62, breakup);
	float turbulent = whitewater_strength * smoothstep(0.12, 0.65, field.b);
	foam = max(foam, turbulent * smoothstep(0.4, 0.65, breakup) * 0.55 * foam_amount);
	if (foam_detail) {
		float foam_phase = fract(river_render_time(simulation_time_s) / 1.5);
		float foam_phase2 = fract(foam_phase + 0.5);
		vec2 foam_position = p - foam_reference_flow * (waterfall_clock_enabled ? river_render_time(simulation_time_s) * speed_m_s : flow_distance_m);
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
		float dense_threshold = waterfall_enabled ? mix(0.58, 0.5, fresh_weight) : mix(0.36, 0.24, fresh_weight);
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
	RADIANCE = vec4(reflection.rgb, reflection_weight * surface_detail * (1.0 - foam));
	vec3 nx = dFdx(normal_world);
	vec3 ny = dFdy(normal_world);
	float variance = min(dot(nx, nx) + dot(ny, ny), 1.0);
	float polished = clamp(roughness * 0.28, 0.025, 0.07);
	float water_roughness = mix(roughness, sqrt(polished * polished + variance * 0.08), surface_detail);
	ROUGHNESS = mix(water_roughness, 0.72, foam);
	SPECULAR = mix(mix(0.18, 0.35, surface_detail), 0.12, foam);
	ALPHA = wet_coverage;
}
