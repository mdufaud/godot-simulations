// Procedural ocean shader — Gerstner geometry waves + analytic FBM detail normals,
// procedural foam (crest / shore / ripple), Schlick fresnel, fake subsurface scattering,
// screen-space refraction with Beer's law absorption, interactive ripple heightmap.
// No external textures required. Wave params are pushed by water_controller.gd and
// mirrored in water_buoyancy.gd for physics sync.

shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// Gerstner geometry waves: xy = direction, z = steepness, w = wavelength
uniform vec4 gerstner_waves[6];
uniform float wave_time = 0.0;
uniform float wave_height = 1.0;
uniform float choppiness = 1.0;

// High-frequency detail normals (analytic, fragment)
uniform float detail_strength = 0.35;

// Interactive ripple heightmap (ping-pong SubViewport, R = height + 0.5, G = prev)
uniform sampler2D ripple_texture : hint_default_black;
uniform vec2 water_area = vec2(128.0, 128.0);
uniform float ripple_strength = 1.0;

// Volume
uniform float refraction = 0.075;
uniform vec4 color_deep : source_color = vec4(0.04, 0.22, 0.32, 1.0);
uniform vec4 color_shallow : source_color = vec4(0.12, 0.5, 0.55, 1.0);
uniform float beers_law = 2.0;
uniform float depth_offset = -0.75;

// Foam & subsurface scattering
uniform float foam_amount = 1.0;
uniform float sss_strength = 1.0;
uniform vec4 sss_color : source_color = vec4(0.1, 0.55, 0.45, 1.0);
uniform vec3 sun_direction = vec3(0.5, -0.6, -0.6);

varying vec3 world_pos;
varying vec3 base_normal;
varying float wave_crest;
varying float view_dist;

const float TAU_C = 6.28318530718;


void vertex()
{
	vec2 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec3 offset = vec3(0.0);
	vec2 grad = vec2(0.0);
	float crest = 0.0;
	float steep_total = 0.001;

	for (int i = 0; i < 6; i++)
	{
		vec4 w = gerstner_waves[i];
		if (w.w < 0.01) { continue; }
		float k = TAU_C / w.w;
		float speed = sqrt(9.8 / k);
		vec2 d = normalize(w.xy);
		float f = k * (dot(d, p) - speed * wave_time);
		float a = (w.z / k) * wave_height;
		float s = sin(f);
		float c = cos(f);

		offset += vec3(d.x * a * choppiness * c, a * s, d.y * a * choppiness * c);
		grad += d * (k * a * c);
		crest += w.z * wave_height * max(s, 0.0);
		steep_total += w.z * wave_height;
	}
	wave_crest = clamp(crest / steep_total, 0.0, 1.0);

	vec2 ripple_uv = p / water_area + 0.5;
	float ripple_h = (textureLod(ripple_texture, ripple_uv, 0.0).r - 0.5) * ripple_strength;

	VERTEX += offset;
	VERTEX.y += ripple_h;

	world_pos = vec3(p.x + offset.x, offset.y, p.y + offset.z);
	base_normal = normalize(vec3(-grad.x, 1.0, -grad.y));
	NORMAL = base_normal;
	view_dist = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}


float hash21(vec2 p)
{
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Analytic gradient of a sum of exp-sine octaves (sharp-crested detail waves)
vec2 detail_gradient(vec2 p, float t)
{
	vec2 grad = vec2(0.0);
	vec2 dir = normalize(vec2(1.0, 0.32));
	mat2 rot = mat2(vec2(0.54, -0.84), vec2(0.84, 0.54));
	float amp = 1.0;
	float freq = 0.9;
	float total = 0.0;

	for (int i = 0; i < 16; i++)
	{
		float x = dot(dir, p) * freq + t * (0.8 + 0.13 * float(i));
		float wave = exp(sin(x) - 1.0);
		grad += dir * (wave * cos(x) * amp * freq);
		total += amp;
		dir = rot * dir;
		freq *= 1.23;
		amp *= 0.79;
	}
	return grad / total;
}


void fragment()
{
	// --- Normal: base (Gerstner) + analytic detail + ripple gradient ---
	// Fade detail with distance to avoid specular aliasing on far water
	float detail_fade = exp(-view_dist * 0.02);
	vec2 det_grad = detail_gradient(world_pos.xz, wave_time) * detail_strength * detail_fade;

	vec2 ripple_uv = world_pos.xz / water_area + 0.5;
	vec2 texel = 1.0 / vec2(textureSize(ripple_texture, 0));
	float rl = texture(ripple_texture, ripple_uv - vec2(texel.x, 0.0)).r;
	float rr = texture(ripple_texture, ripple_uv + vec2(texel.x, 0.0)).r;
	float rd = texture(ripple_texture, ripple_uv - vec2(0.0, texel.y)).r;
	float ru = texture(ripple_texture, ripple_uv + vec2(0.0, texel.y)).r;
	vec2 ripple_grad = vec2(rr - rl, ru - rd) * ripple_strength * 8.0;

	vec2 g = det_grad + ripple_grad;
	vec3 n_world = normalize(base_normal + vec3(-g.x, 0.0, -g.y));
	if (!FRONT_FACING) { n_world = -n_world; }
	vec3 n_view = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	NORMAL = n_view;

	// --- Fresnel (Schlick, F0 water = 0.02) ---
	float ndv = clamp(dot(n_view, VIEW), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

	// --- Screen-space refraction ---
	vec2 ref_uv = SCREEN_UV + n_view.xy * refraction / max(view_dist * 0.2, 1.0);
	ref_uv = clamp(ref_uv, vec2(0.001), vec2(0.999));

	if (FRONT_FACING)
	{
		float depth_raw = texture(DEPTH_TEXTURE, ref_uv).r;
		float depth_lin = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
		// Refracted sample above the surface: fall back to unrefracted
		if (depth_lin + VERTEX.z > 0.0)
		{
			ref_uv = SCREEN_UV;
			depth_raw = texture(DEPTH_TEXTURE, ref_uv).r;
			depth_lin = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
		}
		float water_depth = depth_lin + VERTEX.z;

		// --- Beer's law absorption ---
		float depth_blend = clamp(1.0 - exp((water_depth + depth_offset) * -beers_law), 0.0, 1.0);
		float depth_blend_pow = pow(depth_blend, 2.5);

		vec3 screen_color = textureLod(SCREEN_TEXTURE, ref_uv, depth_blend_pow * 2.5).rgb;
		vec3 dye = mix(color_shallow.rgb, color_deep.rgb, depth_blend_pow);
		vec3 color = mix(screen_color * dye, dye * 0.5, depth_blend_pow * 0.5);

		// --- Procedural foam: wave crests + shoreline + ripple agitation ---
		float foam_noise = value_noise(world_pos.xz * 2.1 + vec2(wave_time * 0.5)) * 0.6
			+ value_noise(world_pos.xz * 5.7 - vec2(wave_time * 0.8)) * 0.4;
		// Noise averages to ~0.5 at distance (minification); pull it below the foam
		// thresholds so far water doesn't turn uniformly snowy
		foam_noise = mix(foam_noise, 0.25, smoothstep(30.0, 90.0, view_dist));
		float crest_foam = smoothstep(0.55, 0.85, wave_crest) * smoothstep(0.3, 0.7, foam_noise);
		// Narrow band: the depth buffer sees floating objects as "shallow water",
		// so a wide band paints a foam halo around anything near the surface
		float shore_foam = (1.0 - smoothstep(0.0, 0.25 + foam_noise * 0.25, water_depth))
			* smoothstep(0.35, 0.6, foam_noise);
		float ripple_foam = smoothstep(0.35, 0.8, length(ripple_grad)) * smoothstep(0.25, 0.55, foam_noise);
		float foam = clamp((crest_foam + shore_foam + ripple_foam) * foam_amount, 0.0, 1.0);
		color = mix(color, vec3(0.95), foam);

		// --- Fake subsurface scattering (light through crests toward camera) ---
		vec3 sun_view = normalize((VIEW_MATRIX * vec4(normalize(sun_direction), 0.0)).xyz);
		float sss = pow(max(dot(VIEW, sun_view), 0.0), 3.0) * wave_crest * sss_strength;
		color += sss_color.rgb * sss * (1.0 - foam);

		ALBEDO = color;
		METALLIC = 0.0;
		ROUGHNESS = mix(0.03, 0.3, foam);
		SPECULAR = 0.2 + fresnel * 0.5;
	}
	else
	{
		// Underside: refracted view of the air above; grazing angles fall into
		// total internal reflection and return the deep water color
		vec3 above = textureLod(SCREEN_TEXTURE, ref_uv, 0.0).rgb;
		float tir = 1.0 - smoothstep(0.45, 0.7, ndv);
		vec3 color = mix(above * color_shallow.rgb * 1.6, color_deep.rgb, tir);

		ALBEDO = color;
		METALLIC = 0.0;
		ROUGHNESS = 0.05;
		SPECULAR = 0.3;
	}
}
