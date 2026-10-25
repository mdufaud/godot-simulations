// Separable gaussian for the thickness buffer: the raw additive accumulation
// keeps per-particle ripples that the composite amplifies through the
// refraction offset and absorption — the horizontal banding on settled water.
// Run twice: direction (1,0) then (0,1). Empty samples (thickness 0, i.e. no
// fluid) are skipped rather than smeared into the edges, same convention as
// the depth filter. R = thickness, G = attribute-weighted thickness (lava
// temperature) or, with B, flow-weighted thickness.
shader_type canvas_item;

uniform sampler2D thickness_tex : filter_nearest;
uniform vec2 direction = vec2(1.0, 0.0);

void fragment() {
	vec3 c0 = texture(thickness_tex, UV).rgb;
	vec2 texel = direction / vec2(textureSize(thickness_tex, 0));
	vec3 sum = c0;
	float wsum = 1.0;
	for (int i = 1; i <= 5; i++) {
		float w = exp(-float(i * i) / 9.0);
		vec3 ca = texture(thickness_tex, UV + texel * float(i)).rgb;
		vec3 cb = texture(thickness_tex, UV - texel * float(i)).rgb;
		if (ca.r > 0.001) {
			sum += ca * w;
			wsum += w;
		}
		if (cb.r > 0.001) {
			sum += cb * w;
			wsum += w;
		}
	}
	COLOR = vec4(sum / wsum, 1.0);
}
