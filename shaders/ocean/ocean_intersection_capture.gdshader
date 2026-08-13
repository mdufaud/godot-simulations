shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

#define CASCADES 3

uniform sampler2DArray displacements : filter_linear, repeat_enable;
uniform vec4 map_scales[CASCADES];
uniform float intersection_width = 1.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float water_height = 0.0;
	for (int i = 0; i < CASCADES; i++) {
		water_height += texture(displacements,
			vec3(world_position.xz * map_scales[i].xy, float(i))).y;
	}
	float intersection = 1.0 - smoothstep(0.12, intersection_width,
		abs(world_position.y - water_height));
	if (intersection < 0.002) {
		discard;
	}
	ALBEDO = vec3(intersection);
}
