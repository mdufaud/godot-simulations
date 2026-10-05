shader_type spatial;
#include "res://shaders/ocean/ocean_deformation.gdshaderinc"
render_mode unshaded, cull_disabled, shadows_disabled;

#define CASCADES 3

uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform vec4 map_scales[CASCADES];
uniform vec3 cascade_wavelengths = vec3(48.0, 7.5, 0.72);
uniform vec3 main_camera_position = vec3(0.0);
uniform vec2 mesh_center = vec2(0.0);
uniform float clipmap_cell = 0.25;
uniform float clipmap_half_extent = 8.0;
uniform float clipmap_ring_levels = 8.0;
uniform int num_cascades = CASCADES;
uniform int geometry_cascade = -1;
uniform float intersection_width = 1.0;
uniform bool local_waves_enabled = false;
uniform sampler2D coast_field : filter_linear, repeat_disable;
uniform sampler2D wake_field : filter_linear, repeat_disable;
uniform vec4 local_centers = vec4(90.0, 35.0, 0.0, 0.0);
uniform vec2 local_domains = vec2(256.0, 64.0);

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float cascade_wavelength(int index) {
	return index == 0 ? cascade_wavelengths.x
		: (index == 1 ? cascade_wavelengths.y : cascade_wavelengths.z);
}

float geometry_weight(vec2 q, int cascade, out float cell) {
	vec2 p = q - mesh_center;
	float cheb = max(abs(p.x), abs(p.y));
	float k = clamp(ceil(log2(max(cheb, 1.0) / clipmap_half_extent) - 0.001),
		0.0, clipmap_ring_levels);
	cell = clipmap_cell * exp2(k);
	float dist = length(vec3(q.x, 0.0, q.y) - main_camera_position);
	float tile = 1.0 / max(map_scales[cascade].x, 1e-6);
	float fade = min(exp(-(dist - max(tile * 0.7, 60.0))
		* 2.5 / max(tile, 80.0)), 1.0);
	float wavelength = cascade_wavelength(cascade);
	return fade * (1.0 - smoothstep(wavelength * 0.18,
		wavelength * 0.48, cell));
}

vec3 sample_surface_displacement(vec2 q) {
	vec3 displacement = vec3(0.0);
	for (int i = 0; i < CASCADES; i++) {
		if (i >= num_cascades || (geometry_cascade >= 0 && i != geometry_cascade)) {
			continue;
		}
		float cell;
		float weight = geometry_weight(q, i, cell);
		if (weight < 0.005) {
			continue;
		}
		vec3 coords = vec3(q * map_scales[i].xy, float(i));
		vec3 d = textureLod(displacements, coords, 0.0).xyz;
		displacement += d * map_scales[i].z * weight;
	}
	return displacement;
}

vec3 surface_displacement(vec2 q, out mat2 horizontal_jacobian) {
	vec3 displacement = sample_surface_displacement(q);
	float epsilon = 0.025;
	vec3 x_plus = sample_surface_displacement(q + vec2(epsilon, 0.0));
	vec3 x_minus = sample_surface_displacement(q - vec2(epsilon, 0.0));
	vec3 z_plus = sample_surface_displacement(q + vec2(0.0, epsilon));
	vec3 z_minus = sample_surface_displacement(q - vec2(0.0, epsilon));
	vec2 derivative_x = (x_plus.xz - x_minus.xz) / (2.0 * epsilon);
	vec2 derivative_z = (z_plus.xz - z_minus.xz) / (2.0 * epsilon);
	horizontal_jacobian = mat2(
		vec2(1.0 + derivative_x.x, derivative_x.y),
		vec2(derivative_z.x, 1.0 + derivative_z.y));
	return displacement;
}

void fragment() {
	vec2 q = world_position.xz;
	vec2 target = q;
	vec3 displacement = vec3(0.0);
	mat2 jacobian = mat2(1.0);
	for (int iteration = 0; iteration < 8; iteration++) {
		displacement = surface_displacement(q, jacobian);
		vec2 residual = q + displacement.xz - target;
		float jacobian_determinant = determinant(jacobian);
		float safe_determinant = (jacobian_determinant < 0.0 ? -1.0 : 1.0)
			* max(abs(jacobian_determinant), 0.08);
		q -= vec2(jacobian[1][1] * residual.x - jacobian[1][0] * residual.y,
			-jacobian[0][1] * residual.x + jacobian[0][0] * residual.y)
			/ safe_determinant;
	}
	displacement = surface_displacement(q, jacobian);
	float inverse_residual = length(q + displacement.xz - target);
	if (inverse_residual > 0.001) {
		discard;
	}
	float water_height = displacement.y;
	if (local_waves_enabled) {
		water_height += ocean_local_sample(coast_field, local_centers.xy,
			local_domains.x, target).x + ocean_local_sample(wake_field,
			local_centers.zw, local_domains.y, target).x;
	}
	float intersection = 1.0 - smoothstep(0.12, intersection_width,
		abs(world_position.y - water_height));
	if (intersection < 0.002) {
		discard;
	}
	ALBEDO = vec3(intersection);
}
