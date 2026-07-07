// Separable narrow-range depth filter (Truong et al. 2018): Gaussian blur with
// samples clamped into a depth window around the center so silhouettes stay
// sharp and background never bleeds in. Run twice: direction (1,0) then (0,1).
// Depth is packed R = floor(d), G = fract(d) to survive 16F render targets.
shader_type canvas_item;

uniform sampler2D depth_tex : filter_nearest;
uniform vec2 direction = vec2(1.0, 0.0);
uniform float particle_radius = 0.12;
uniform float proj_scale = 470.0;
uniform float range_scale = 3.0;

float depth_at(vec2 uv) {
	vec2 rg = texture(depth_tex, uv).rg;
	return rg.x + rg.y;
}

void fragment() {
	float d0 = depth_at(UV);
	if (d0 <= 0.001) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		// Filter radius shrinks with distance: constant world-space footprint
		float radius_px = clamp(proj_scale * particle_radius / d0, 1.0, 16.0);
		float sigma = radius_px * 0.5;
		float two_sigma2 = 2.0 * sigma * sigma;
		float delta = range_scale * particle_radius;
		float low = d0 - delta;
		float high = d0 + delta;
		vec2 texel = direction / vec2(textureSize(depth_tex, 0));
		float sum = d0;
		float asum = texture(depth_tex, UV).b;
		float wsum = 1.0;
		for (int i = 1; i <= 16; i++) {
			if (float(i) > radius_px) {
				break;
			}
			float w = exp(-float(i * i) / two_sigma2);
			vec2 uva = UV + texel * float(i);
			vec2 uvb = UV - texel * float(i);
			float da = depth_at(uva);
			float db = depth_at(uvb);
			if (da > 0.001) {
				sum += clamp(da, low, high) * w;
				asum += texture(depth_tex, uva).b * w;
				wsum += w;
			}
			if (db > 0.001) {
				sum += clamp(db, low, high) * w;
				asum += texture(depth_tex, uvb).b * w;
				wsum += w;
			}
		}
		float d = sum / wsum;
		COLOR = vec4(floor(d), d - floor(d), asum / wsum, 1.0);
	}
}
