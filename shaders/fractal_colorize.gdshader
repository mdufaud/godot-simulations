shader_type canvas_item;

// ============================================================
// Fractal colorize pass — runs every frame, trivially cheap.
// Reads iteration data from the two SubViewports (low = live
// preview, high = refined) and maps it to color. Palette
// animation via TIME costs nothing: the fractal itself is not
// recomputed here.
//
// Input packing (see fractal.gdshader):
//   R = floor(mu / 64), G = mu - R*64, B = trap, A = coverage
// ============================================================

uniform sampler2D tex_low : filter_linear, repeat_disable;
uniform sampler2D tex_high : filter_linear, repeat_disable;
uniform float refine_blend : hint_range(0.0, 1.0) = 0.0;

uniform int color_mode : hint_range(0, 3) = 0;
uniform float color_speed : hint_range(0.0, 5.0) = 0.3;
uniform float color_offset : hint_range(0.0, 1.0) = 0.0;
uniform float edge_strength : hint_range(0.0, 1.0) = 0.35;

const vec3 PAL0_A = vec3(0.500, 0.500, 0.500);
const vec3 PAL0_B = vec3(0.500, 0.500, 0.500);
const vec3 PAL0_C = vec3(1.000, 1.000, 1.000);
const vec3 PAL0_D = vec3(0.000, 0.333, 0.667);

const vec3 PAL1_A = vec3(0.500, 0.500, 0.500);
const vec3 PAL1_B = vec3(0.500, 0.500, 0.500);
const vec3 PAL1_C = vec3(0.800, 1.000, 0.500);
const vec3 PAL1_D = vec3(0.000, 0.150, 0.250);

const vec3 PAL2_A = vec3(0.700, 0.400, 0.300);
const vec3 PAL2_B = vec3(0.300, 0.500, 0.300);
const vec3 PAL2_C = vec3(2.500, 1.000, 0.800);
const vec3 PAL2_D = vec3(0.000, 0.200, 0.300);

const vec3 PAL3_A = vec3(0.200, 0.600, 0.700);
const vec3 PAL3_B = vec3(0.800, 0.400, 0.300);
const vec3 PAL3_C = vec3(0.500, 1.500, 1.000);
const vec3 PAL3_D = vec3(0.000, 0.100, 0.500);

vec3 cosine_palette(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
	return a + b * cos(6.28318 * (c * t + d));
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

vec4 fetch(vec2 uv) {
	return mix(texture(tex_low, uv), texture(tex_high, uv), refine_blend);
}

float decode_mu(vec4 d) {
	return d.r * 64.0 + d.g;
}

vec3 exterior_color(float mu, float trap) {
	// Log-compressed iteration scale: keeps color progression perceptually
	// uniform across zoom depths and kills chromatic noise near the set
	float ms = log2(1.0 + mu);
	float dim = 0.22 + 0.78 * smoothstep(0.0, 5.0, ms);

	if (color_mode == 1) {
		float phase = trap * 0.9 + ms * 0.03 + TIME * color_speed * 0.4 + color_offset;
		vec3 col = cosine_palette(phase, PAL2_A, PAL2_B, PAL2_C, PAL2_D);
		float b = 1.0 - clamp(trap, 0.0, 1.0);
		return mix(col, col * 1.4, b * b) * dim;
	}
	if (color_mode == 2) {
		float hue = fract(ms * 0.16 + TIME * color_speed * 0.25 + color_offset);
		float lum = 0.4 + 0.6 * (0.5 + 0.5 * sin(ms * 0.9 + TIME * 0.5));
		vec3 col = hsv2rgb(vec3(hue, 0.95, lum));
		return col * dim;
	}
	if (color_mode == 3) {
		float t = fract(ms * 0.14 + TIME * color_speed * 0.05 + color_offset);
		vec3 col = vec3(0.0);
		col = mix(col, vec3(0.1, 0.0, 0.5), smoothstep(0.0, 0.10, t));
		col = mix(col, vec3(0.7, 0.0, 0.1), smoothstep(0.08, 0.25, t));
		col = mix(col, vec3(1.0, 0.25, 0.0), smoothstep(0.25, 0.45, t));
		col = mix(col, vec3(1.0, 0.75, 0.1), smoothstep(0.45, 0.65, t));
		col = mix(col, vec3(1.0, 0.95, 0.5), smoothstep(0.65, 0.85, t));
		col = mix(col, vec3(1.0, 1.0, 1.0), smoothstep(0.85, 1.00, t));
		return col * dim;
	}
	float phase = ms * 0.12 + TIME * color_speed * 0.12 + color_offset;
	vec3 col = cosine_palette(phase, PAL0_A, PAL0_B, PAL0_C, PAL0_D);
	return col * dim;
}

vec3 interior_color(float trap) {
	if (color_mode == 3) return vec3(0.0);
	if (color_mode == 2) return vec3(0.02, 0.0, 0.04);
	return cosine_palette(trap * 0.6 + color_offset + 0.5, PAL3_A, PAL3_B, PAL3_C, PAL3_D) * 0.15;
}

void fragment() {
	vec4 d = fetch(UV);
	float mu = decode_mu(d);
	float trap = d.b;
	float coverage = d.a;

	vec3 ext = exterior_color(mu, trap);

	// Slope shading: emboss from the mu gradient (neighbor texels are free)
	if (edge_strength > 0.001 && coverage > 0.0) {
		vec2 ts = 1.0 / vec2(textureSize(tex_high, 0));
		float ml = decode_mu(fetch(UV - vec2(ts.x, 0.0)));
		float mr = decode_mu(fetch(UV + vec2(ts.x, 0.0)));
		float mt = decode_mu(fetch(UV - vec2(0.0, ts.y)));
		float mb = decode_mu(fetch(UV + vec2(0.0, ts.y)));
		vec2 g = vec2(mr - ml, mb - mt);
		float e = dot(g, vec2(-0.707, -0.707));
		e = e / (1.0 + abs(e));
		ext *= 1.0 + edge_strength * 0.55 * e;
	}

	vec3 col = mix(interior_color(trap), ext, coverage);

	// Fine dither to kill palette banding
	float grain = fract(sin(dot(UV, vec2(12.9898, 78.233))) * 43758.5453);
	col += (grain - 0.5) * 0.008;

	COLOR = vec4(col, 1.0);
}
