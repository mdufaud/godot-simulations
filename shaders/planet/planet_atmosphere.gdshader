// Raymarched Rayleigh atmosphere, composited over the whole screen. Port of
// Atmosphere.shader from SebLague/Fluid-Planet, minus its dead ocean branch.
// Deliberately has no phase function, matching the original. The maths lives in
// atmosphere.gdshaderinc because the fluid composite has to scatter its own
// output too -- see the note there.
//
// Mounted the same way as the fluid composite: a 2x2 QuadMesh on a MeshInstance3D
// with a huge custom_aabb, snapped to the near plane in vertex().
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
#include "res://shaders/planet/atmosphere.gdshaderinc"

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 original_col = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;

	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec4 view_far = INV_PROJECTION_MATRIX * vec4(ndc, 1.0, 1.0);
	vec3 view_ray = view_far.xyz / view_far.w;
	vec3 ray_dir = normalize((INV_VIEW_MATRIX * vec4(view_ray, 0.0)).xyz);
	vec3 ray_origin = CAMERA_POSITION_WORLD;

	// Distance from the camera to whatever the depth buffer holds. Godot uses
	// reverse Z, so a raw depth of 0 is the far plane and lands far past the shell.
	float raw_depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	float scene_dist = MAX_DIST;
	if (raw_depth > 0.0) {
		vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, raw_depth, 1.0);
		scene_dist = length(view_pos.xyz / view_pos.w);
	}

	// Writing ALPHA puts the quad in the transparent queue, which is the only place
	// DEPTH_TEXTURE holds the resolved opaque depth.
	ALPHA = 1.0;

	vec2 hit_info = ray_sphere(planet_centre, atmosphere_radius, ray_origin, ray_dir);
	float dst_to_atmosphere = hit_info.x;
	float dst_through_atmosphere = min(hit_info.y, scene_dist - dst_to_atmosphere);

	if (dst_through_atmosphere > 0.0) {
		const float epsilon = 0.0001;
		vec3 point_in_atmosphere = ray_origin + ray_dir * (dst_to_atmosphere + epsilon);
		ALBEDO = calculate_light(point_in_atmosphere, ray_dir, dst_through_atmosphere - epsilon * 2.0,
				original_col, SCREEN_UV, VIEWPORT_SIZE);
	} else {
		ALBEDO = original_col;
	}
}
