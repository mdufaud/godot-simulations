// Water body billboards for the fire demo's SPH water (FireWater).
//
// One camera-facing quad per particle, raised to a sphere in the fragment stage.
// The droplets are drawn larger than the SPH spacing and rendered as translucent,
// refracting water rather than opaque beads, so where they overlap they read as
// one connected body of water — a cheap stand-in for a screen-space fluid surface
// that stays inside this scene's transparent pass with no extra render targets.
//
// Position comes from the SPH solver's position texture, indexed by INSTANCE_ID;
// its w lane is the particle speed (temperature only in lava mode), which adds a
// little foam-white to fast-moving water so a splash reads as motion.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform sampler2D position_tex : filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform int tex_width = 256;
uniform float particle_radius = 0.13;
uniform float refraction : hint_range(0.0, 0.1) = 0.035;
uniform vec3 deep_color : source_color = vec3(0.04, 0.13, 0.22);
uniform vec3 tint_color : source_color = vec3(0.55, 0.74, 0.9);
uniform vec3 rim_color : source_color = vec3(0.6, 0.78, 0.95);

varying vec2 quad_uv;
varying vec3 center_view;
varying float speed;

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	speed = particle.w;
	quad_uv = UV * 2.0 - 1.0;
	center_view = (VIEW_MATRIX * vec4(particle.xyz, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(center_view + vec3(quad_uv * particle_radius, 0.0), 1.0);
}

void fragment() {
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	float nz = sqrt(1.0 - r2);

	// Raise the flat quad to a sphere so overlapping droplets occlude by real depth.
	vec3 sphere_view = center_view + vec3(quad_uv, nz) * particle_radius;
	vec4 clip = PROJECTION_MATRIX * vec4(sphere_view, 1.0);
	DEPTH = clip.z / clip.w;

	// View-space normal of the sphere point; nz is its facing-ness to the camera.
	NORMAL = vec3(quad_uv, nz);

	// Refract the scene behind the droplet: offset the screen sample by the surface
	// tilt, tint it for absorption. Overlapping translucent droplets then stack
	// toward the deep colour, which is the "thickness" read.
	vec2 refr_uv = SCREEN_UV + quad_uv * refraction;
	vec3 bg = texture(screen_tex, refr_uv).rgb;
	float fres = pow(1.0 - nz, 3.0);

	ALBEDO = deep_color;
	// Background shows through the body, whitening to foam at grazing edges and on
	// fast-moving water.
	EMISSION = bg * tint_color * (1.0 - fres)
		+ rim_color * (fres * 0.6 + 0.15 * clamp(speed, 0.0, 4.0));
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	RIM = 0.3;
	RIM_TINT = 0.2;
	ALPHA = clamp(0.55 + fres * 0.45, 0.0, 1.0);
}
