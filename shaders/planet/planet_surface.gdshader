// Planet surface shading. Port of MarchingCubesDraw.shader from SebLague/Fluid-Planet.
// No textures and no triplanar: the colour is a quantised height band crossed with a
// flat/steep threshold, lit by a half-lambert against a single sun direction.
// Unshaded on purpose -- the original does its own lighting and samples no shadow map.
shader_type spatial;
render_mode unshaded;

#include "res://shaders/planet/simplex_noise.gdshaderinc"

uniform vec3 sun_direction = vec3(0.5, 0.4, 0.75);

uniform vec3 col_flat : source_color = vec3(0.670, 0.465, 0.281);
uniform vec3 col_flat_deep : source_color = vec3(0.434, 0.180, 0.166);
uniform vec3 col_steep : source_color = vec3(0.368, 0.270, 0.227);
uniform vec3 col_steep_deep : source_color = vec3(0.208, 0.153, 0.179);
uniform vec3 col_ambient : source_color = vec3(0.500, 0.390, 0.389);

uniform float shade_pow = 1.5;
uniform float flat_threshold = 0.76;
uniform float flat_blend = 0.01;
// Height range the colour gradient spans, and how many discrete bands it is cut into.
uniform float height_min = 16.2;
uniform float height_max = 28.3;
uniform float height_bands = 5.2;

// Detail noise perturbing both the height band and the surface normal.
uniform int detail_octaves : hint_range(0, 8) = 8;
uniform float detail_scale = 1.0;
uniform float detail_persistence = 0.11;
uniform float detail_lacunarity = 2.0;
uniform float detail_offset = 0.82;
uniform float detail_strength = 0.25;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// continent_noise gets detail_scale as both the position multiplier and the base
	// frequency, exactly as in the original -- the squared frequency is part of the look.
	float noise = 0.0;
	if (detail_octaves > 0) {
		noise = (continent_noise(world_pos * detail_scale, detail_octaves,
				detail_persistence, detail_lacunarity, detail_scale) - detail_offset) * detail_strength;
	}

	vec3 simple_normal = normalize(world_normal);
	// Adding a scalar to a vector is deliberate: a cheap directional wobble.
	vec3 detail_normal = normalize(world_normal + noise);

	vec3 shading = vec3(dot(normalize(sun_direction), simple_normal) * 0.5 + 0.5);
	shading += col_ambient;
	shading = pow(max(shading, vec3(0.0)), vec3(shade_pow));

	float height_t = (length(world_pos) - height_min + noise) / max(height_max - height_min, 0.001);
	height_t = clamp(height_t, 0.0, 1.0);
	// Posterising the gradient is what produces the terraced look.
	height_t = float(int(height_t * height_bands)) / height_bands;

	// 1 where the surface faces straight out from the core, 0 on a vertical cliff.
	float flatness = dot(normalize(world_pos), detail_normal);
	float flat_t = smoothstep(-flat_blend, flat_blend, flatness - flat_threshold);

	vec3 c_flat = mix(col_flat_deep, col_flat, height_t);
	vec3 c_steep = mix(col_steep_deep, col_steep, height_t);
	ALBEDO = mix(c_flat, c_steep, 1.0 - flat_t) * shading;
}
