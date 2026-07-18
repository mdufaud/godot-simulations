shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// Photoscanned vegetation (Poly Haven): PBR maps, double-sided opaque geometry
// (leaves are real geometry, not alpha cards). Wind sway scales with height
// above the instance origin; understory plants can follow the terrain
// heightmap so their tiles recenter like the grass tiles.

global uniform sampler2D heightmap : repeat_enable;
global uniform float heightmap_scale;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D arm_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform float sway_amount = 0.0;
uniform float wind_strength = 1.0;
uniform float height_ref = 10.0;
uniform bool follow_terrain = false;
uniform vec3 backlight_color : source_color = vec3(0.0);
uniform float albedo_boost = 1.0;
uniform float hue_jitter = 0.12;
uniform float value_jitter = 0.22;

varying float ihash;
varying float ihash2;

float hash12(vec2 x) {
	uvec2 p = floatBitsToUint(x);
	p = 1103515245U * ((p >> 1U) ^ (p.yx));
	uint h32 = 1103515245U * ((p.x) ^ (p.y >> 3U));
	uint n = h32 ^ (h32 >> 16U);
	return float(n) * (1.0 / float(0xffffffffU));
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void vertex() {
	vec2 origin = MODEL_MATRIX[3].xz;
	ihash = hash12(origin);
	ihash2 = hash12(origin + vec2(37.1, 91.7));
	if (follow_terrain) {
		vec2 tex_size = vec2(textureSize(heightmap, 0));
		float h = texture(heightmap, origin / tex_size).r;
		VERTEX.y += (h - 0.5) * heightmap_scale;
	}
	float rel = clamp((VERTEX.y - MODEL_MATRIX[3].y) / max(height_ref, 0.001), 0.0, 1.0);
	float phase = ihash * 6.283;
	float gust = sin(TIME * 0.9 + phase) + 0.45 * sin(TIME * 1.9 + phase * 1.7);
	float amp = sway_amount * wind_strength * rel * rel * 0.10;
	VERTEX.x += gust * amp;
	VERTEX.z += gust * amp * 0.6;
	VERTEX.y += sway_amount * wind_strength * rel
			* sin(TIME * 3.1 + VERTEX.x * 1.7 + phase) * 0.015;
}

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb * albedo_boost;
	// Per-instance hue/value drift so a field of one scan does not read as a
	// stamped pattern: shift hue toward yellow-green or blue-green and vary
	// brightness. ihash/ihash2 are unique per instance (from world origin).
	vec3 hsv = rgb2hsv(base);
	hsv.x = fract(hsv.x + (ihash - 0.5) * hue_jitter);
	hsv.z *= 1.0 + (ihash2 - 0.5) * value_jitter;
	hsv.y *= 0.85 + ihash * 0.3;
	ALBEDO = hsv2rgb(hsv);
	vec3 arm = texture(arm_tex, UV).rgb;
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.25;
	ROUGHNESS = arm.g;
	METALLIC = 0.0;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	BACKLIGHT = backlight_color;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
