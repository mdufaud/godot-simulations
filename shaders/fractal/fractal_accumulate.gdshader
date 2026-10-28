shader_type canvas_item;
render_mode blend_disabled;

// ============================================================
// Fractal accumulation pass — full window resolution, ping-pong.
// Each pixel carries the running mean of every sample it got:
//   R = floor(muc / mu_split), G = muc - R * mu_split   (muc = mean of mu * escaped)
//   B = mean trap, A = coverage (mean of escaped)
// so mu = muc / coverage, and every channel filters linearly.
//
// The history buffer was rendered for an older view: it is
// resampled (Catmull-Rom) through an exact float64-derived
// transform, so a zoom magnifies real pixels instead of
// stretching a low-res preview. Pixels in this frame's sample
// slot blend in their fresh sample; pixels with no history yet
// (zoom-out border, fresh content) take the upsampled samples.
// ============================================================

uniform sampler2D tex_history : filter_nearest, repeat_disable;
uniform sampler2D tex_sample : filter_linear, repeat_disable;

uniform int sample_stride = 1;
uniform int sample_phase = 0;
uniform vec2 sample_jitter = vec2(0.0);

// History UV = xy * UV + zw.
uniform vec4 history_xform = vec4(1.0, 1.0, 0.0, 0.0);
uniform bool history_identity = true;
uniform bool history_valid = false;
uniform float blend_alpha = 1.0;
uniform float mu_max = 20000.0;
uniform float mu_split = 16.0;

#include "res://shaders/fractal/fractal_slots.gdshaderinc"

vec3 decode(vec4 t) {
	return vec3(t.r * mu_split + t.g, t.b, t.a);
}

vec3 history_texel(ivec2 p, ivec2 size) {
	return decode(texelFetch(tex_history, clamp(p, ivec2(0), size - 1), 0));
}

vec3 history_catmull_rom(vec2 uv) {
	ivec2 size = textureSize(tex_history, 0);
	vec2 pos = uv * vec2(size) - 0.5;
	vec2 base = floor(pos);
	vec2 f = pos - base;
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec4 wx = vec4(w0.x, w1.x, w2.x, w3.x);
	vec4 wy = vec4(w0.y, w1.y, w2.y, w3.y);
	ivec2 b = ivec2(base) - 1;
	vec3 acc = vec3(0.0);
	for (int j = 0; j < 4; j++) {
		vec3 row = vec3(0.0);
		for (int i = 0; i < 4; i++) {
			row += wx[i] * history_texel(b + ivec2(i, j), size);
		}
		acc += wy[j] * row;
	}
	return acc;
}

void fragment() {
	ivec2 p = ivec2(floor(UV / SCREEN_PIXEL_SIZE));

	vec3 hist = vec3(0.0);
	bool hist_ok = false;
	if (history_valid) {
		if (history_identity) {
			hist = decode(texelFetch(tex_history, p, 0));
			hist_ok = true;
		} else {
			vec2 uv0 = history_xform.xy * UV + history_xform.zw;
			hist_ok = all(greaterThanEqual(uv0, vec2(0.0))) && all(lessThanEqual(uv0, vec2(1.0)));
			if (hist_ok) {
				hist = history_catmull_rom(uv0);
			}
		}
	}

	vec3 result;
	ivec2 cell = p / sample_stride;
	if (p - cell * sample_stride == fractal_slot_offset(cell, sample_stride, sample_phase)) {
		vec3 s = decode(texelFetch(tex_sample, cell, 0));
		result = hist_ok ? mix(hist, s, blend_alpha) : s;
	} else if (hist_ok) {
		result = hist;
	} else {
		// Samples sit anywhere in their cell: take each at the cell centre.
		vec2 at = (vec2(p) + 0.5) / float(sample_stride);
		result = decode(texture(tex_sample, at / vec2(textureSize(tex_sample, 0))));
	}

	float coverage = clamp(result.z, 0.0, 1.0);
	float muc = clamp(result.x, 0.0, coverage * mu_max);
	float hi = floor(muc / mu_split);
	COLOR = vec4(hi, muc - hi * mu_split, clamp(result.y, 0.0, 1.0), coverage);
}
