// Full-screen stylization gallery for the grass demo. Lives on a CanvasLayer
// BELOW the SimMenu layer: SCREEN_TEXTURE holds the rendered field while the
// menu above stays unfiltered. Obra Dinn thresholds luminance through an
// ordered Bayer8 trame for the 1-bit look; the other modes are duotones and
// false-color around the same luminance.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform int filter_mode : hint_range(0, 5) = 0;

const vec3 PAPER = vec3(0.93, 0.89, 0.80);
const vec3 INK = vec3(0.07, 0.06, 0.08);

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// Compact ordered-dither ladder: a 2x2 checker self-reducing mod 2, grown to
// an 8x8 Bayer pattern. Raw range is [0, 21/16) — dither() normalizes to [0, 1).
float bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
	return bayer2(a * 0.5) * 0.25 + bayer2(a);
}

float dither8(vec2 a) {
	return (bayer4(a * 0.5) * 0.25 + bayer2(a)) * (16.0 / 21.0);
}

float grain(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 scene = texture(screen_tex, SCREEN_UV).rgb;
	float l = luma(scene);
	float dither = dither8(FRAGCOORD.xy);
	vec2 grain_seed = FRAGCOORD.xy + vec2(TIME * 60.0, TIME * 97.0);
	float vig = 1.0 - 0.4 * smoothstep(0.35, 0.85, length(SCREEN_UV - 0.5));
	// The golden-hour field lives in luma [0.209, 0.719] (measured p2..p98
	// after the sunlight rebalance); every mode works on that range stretched
	// toward full, like a percentile pull.
	float stretched = clamp((l - 0.209) * 2.0, 0.0, 1.0);
	vec3 col;

	if (filter_mode == 1) {
		// 1-bit Obra Dinn: threshold dithered luminance between paper and ink.
		float biased = stretched * mix(0.7, 1.2, vig) + (dither - 0.5) * 0.85;
		col = biased > 0.45 ? PAPER : INK;
	} else if (filter_mode == 2) {
		// High-contrast mono, the "dark mask" look.
		float c = stretched * vig;
		c += (dither - 0.5) * (2.0 / 255.0);
		col = vec3(c);
	} else if (filter_mode == 3) {
		// Aged sepia print: brown-to-cream duotone with grain and vignette.
		float c = clamp((l - 0.209) * 1.65, 0.0, 1.0) * vig;
		col = mix(vec3(0.16, 0.10, 0.06), vec3(0.95, 0.87, 0.68), c);
		col += (grain(grain_seed) - 0.5) * 0.06;
	} else if (filter_mode == 4) {
		// Thermal false color: violet body, orange midrange, hot highlights.
		vec3 cold = vec3(0.02, 0.0, 0.10);
		vec3 warm = vec3(0.45, 0.02, 0.35);
		vec3 hot = vec3(0.98, 0.42, 0.05);
		vec3 peak = vec3(1.0, 0.96, 0.60);
		col = stretched < 0.35 ? mix(cold, warm, stretched / 0.35)
			: stretched < 0.7 ? mix(warm, hot, (stretched - 0.35) / 0.35)
			: mix(hot, peak, (stretched - 0.7) / 0.3);
		col *= vig;
		col += (grain(grain_seed) - 0.5) * 0.05;
	} else if (filter_mode == 5) {
		// Green phosphor CRT: duotone plus scanlines and a little grain.
		float c = clamp((l - 0.209) * 1.8, 0.0, 1.0);
		col = mix(vec3(0.02, 0.07, 0.03), vec3(0.50, 0.98, 0.45), pow(c, 0.9));
		col *= 0.82 + 0.18 * sin(FRAGCOORD.y * 3.14159);
		col *= vig;
		col += (grain(grain_seed) - 0.5) * 0.05;
	} else {
		col = scene;
	}

	COLOR = vec4(col, 1.0);
}
