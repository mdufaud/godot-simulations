shader_type spatial;
render_mode unshaded, fog_disabled;
#include "res://shaders/river/scenery_clip.gdshaderinc"

// river_wet_ground probe: scenery coloured by the under-water test river_ground and river_rock run, magenta under the
// water, cyan above it.

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = world_position.y < river_surface_height(world_position) ? vec3(1.0, 0.0, 1.0) : vec3(0.0, 1.0, 1.0);
}
