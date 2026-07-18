// Separable bilateral depth filter: a spatial Gaussian weighted by a
// depth-difference range Gaussian against the pre-blur center depth, so the
// surface smooths but silhouettes/edges are preserved (depth-aware). Run twice:
// direction (1,0) then (0,1). Depth packed R = floor(d), G = fract(d) to survive
// 16F render targets; B carries the attribute (lava temperature).
shader_type canvas_item;

uniform sampler2D depth_tex : filter_nearest;
uniform vec2 direction = vec2(1.0, 0.0);
uniform float particle_radius = 0.12;
uniform float proj_scale = 470.0;
uniform float range_scale = 6.0;

void fragment() {
	vec3 c0 = texture(depth_tex, UV).rgb;
	float d0 = c0.r + c0.g;
	if (d0 <= 0.001) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		// Filter radius shrinks with distance: constant world-space footprint.
		float radius_px = clamp(proj_scale * particle_radius / d0, 1.0, 16.0);
		float sigma = radius_px * 0.5;
		float two_sigma2 = 2.0 * sigma * sigma;
		// Range weight: samples whose depth differs from the center (in world
		// units) are down-weighted, so blur never crosses a silhouette.
		float range_sigma = range_scale * particle_radius;
		float inv_two_range2 = 1.0 / (2.0 * range_sigma * range_sigma);
		vec2 texel = direction / vec2(textureSize(depth_tex, 0));
		float sum = d0;
		float asum = c0.b;
		float wsum = 1.0;
		for (int i = 1; i <= 16; i++) {
			if (float(i) > radius_px) {
				break;
			}
			float spatial = exp(-float(i * i) / two_sigma2);
			vec3 ca = texture(depth_tex, UV + texel * float(i)).rgb;
			vec3 cb = texture(depth_tex, UV - texel * float(i)).rgb;
			float da = ca.r + ca.g;
			float db = cb.r + cb.g;
			if (da > 0.001) {
				float dd = da - d0;
				float w = spatial * exp(-dd * dd * inv_two_range2);
				sum += da * w;
				asum += ca.b * w;
				wsum += w;
			}
			if (db > 0.001) {
				float dd = db - d0;
				float w = spatial * exp(-dd * dd * inv_two_range2);
				sum += db * w;
				asum += cb.b * w;
				wsum += w;
			}
		}
		float d = sum / wsum;
		COLOR = vec4(floor(d), d - floor(d), asum / wsum, 1.0);
	}
}
