// Additive star sprites billboarded from the N-body position texture.
// blend_add needs no sorting; depth_draw_never keeps the stars out of the depth
// buffer while still letting the event horizon occlude the ones behind it.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 512;
uniform float sprite_size = 0.09;
uniform float min_pixel_size = 1.2;
uniform float brightness = 1.0;
uniform vec3 cold_color : source_color = vec3(1.0, 0.32, 0.06);
uniform vec3 warm_color : source_color = vec3(1.0, 0.88, 0.68);
uniform vec3 hot_color : source_color = vec3(0.52, 0.72, 1.0);

varying vec2 quad_uv;
varying vec3 star_color;

float hash11(uint x) {
	x = (x ^ 61u) ^ (x >> 16u);
	x *= 9u;
	x = x ^ (x >> 4u);
	x *= 0x27d4eb2du;
	x = x ^ (x >> 15u);
	return float(x) * (1.0 / 4294967296.0);
}

void vertex() {
	ivec2 texel = ivec2(int(INSTANCE_ID) % tex_width, int(INSTANCE_ID) / tex_width);
	vec4 particle = texelFetch(position_tex, texel, 0);
	float speed = particle.w;
	float jitter = hash11(uint(INSTANCE_ID));

	quad_uv = UV * 2.0 - 1.0;
	vec3 center_view = (VIEW_MATRIX * vec4(particle.xyz, 1.0)).xyz;

	// Below ~1 pixel a sprite starts to strobe and the galaxy dissolves into
	// noise, so clamp the world size to a floor derived from the projection.
	float dist = max(-center_view.z, 1e-3);
	float px_to_world = 2.0 * dist / (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1]);
	float size = max(sprite_size * (0.6 + 0.8 * jitter), min_pixel_size * px_to_world);

	vec3 view_pos = center_view + vec3(quad_uv * size, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);

	vec3 c = mix(cold_color, warm_color, smoothstep(0.10, 0.55, speed));
	c = mix(c, hot_color, smoothstep(0.55, 1.10, speed));
	star_color = c * brightness * (0.7 + 0.6 * jitter);
}

void fragment() {
	float r2 = dot(quad_uv, quad_uv);
	if (r2 > 1.0) {
		discard;
	}
	// Gaussian core, forced to zero at the quad edge so sprites don't show seams.
	float falloff = exp(-5.0 * r2) - exp(-5.0);
	ALBEDO = star_color * falloff;
	ALPHA = 1.0;
}
