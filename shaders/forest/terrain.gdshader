shader_type spatial;

// Heightmap-displaced forest terrain. Samples the same global heightmap with
// the same world.xz / textureSize convention as grass.gdshader so grass,
// collision and terrain agree by construction.

global uniform sampler2D heightmap : filter_linear, repeat_enable;
global uniform float heightmap_scale;

uniform bool low_poly = false;
uniform bool use_textures = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D arm_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_grass_layer = false;
uniform sampler2D grass_albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D grass_arm_tex : hint_default_white, filter_linear_mipmap;
// Extra layers: mossy forest ground as canopy base, pebbles on the path.
uniform bool use_ground_layers = false;
uniform sampler2D ground_albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D ground_normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D ground_arm_tex : hint_default_white, filter_linear_mipmap;
uniform sampler2D pebble_albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D pebble_normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D pebble_arm_tex : hint_default_white, filter_linear_mipmap;
// World-mapped mask like the heightmap: R = clearing noise, G = path.
uniform sampler2D clearing_mask : filter_linear, repeat_enable;
// Poly Haven ground scans are tan; this tint turns the grass layer verdant.
uniform vec3 grass_tint : source_color = vec3(0.60, 0.85, 0.48);
uniform float texture_tile_m = 3.0;
uniform vec3 fallback_color : source_color = vec3(0.16, 0.12, 0.07);
uniform vec3 low_color_valley : source_color = vec3(0.22, 0.34, 0.12);
uniform vec3 low_color_hill : source_color = vec3(0.42, 0.48, 0.20);

varying vec3 world_pos;

float terrain_h(vec2 xz) {
	return (texture(heightmap, xz / vec2(textureSize(heightmap, 0))).r - 0.5) * heightmap_scale;
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += terrain_h(wp.xz);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	float e = 1.0;
	float hx0 = terrain_h(wp.xz - vec2(e, 0.0));
	float hx1 = terrain_h(wp.xz + vec2(e, 0.0));
	float hz0 = terrain_h(wp.xz - vec2(0.0, e));
	float hz1 = terrain_h(wp.xz + vec2(0.0, e));
	NORMAL = normalize(vec3(hx0 - hx1, 2.0 * e, hz0 - hz1));
	TANGENT = normalize(vec3(2.0 * e, hx1 - hx0, 0.0));
	BINORMAL = cross(NORMAL, TANGENT);
}

void fragment() {
	if (low_poly) {
		// Face normals + quantized two-tone ramp by altitude.
		vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		if (face_n.z < 0.0) {
			face_n = -face_n;
		}
		NORMAL = face_n;
		float t = clamp(world_pos.y / heightmap_scale + 0.5, 0.0, 1.0);
		t = floor(t * 4.0) / 3.0;
		ALBEDO = mix(low_color_valley, low_color_hill, t);
		ROUGHNESS = 1.0;
	} else if (use_textures) {
		vec2 uv = world_pos.xz / texture_tile_m;
		vec2 uv_macro = uv * 0.2;
		// Second low-frequency sample breaks the tiling pattern.
		vec3 albedo = mix(texture(albedo_tex, uv).rgb, texture(albedo_tex, uv_macro).rgb, 0.3);
		vec3 nrm = texture(normal_tex, uv).rgb;
		vec3 arm = texture(arm_tex, uv).rgb;
		vec2 mask = texture(clearing_mask,
				world_pos.xz / vec2(textureSize(clearing_mask, 0))).rg;
		if (use_ground_layers) {
			// Mossy forest ground is the base under the canopy; the leaf-litter
			// floor becomes a macro-scale variation layer.
			float vari = texture(clearing_mask, world_pos.xz * 3.7
					/ vec2(textureSize(clearing_mask, 0))).r;
			vec3 g06 = mix(texture(ground_albedo_tex, uv).rgb,
					texture(ground_albedo_tex, uv_macro).rgb, 0.3);
			float floor_mix = smoothstep(0.45, 0.62, vari);
			albedo = mix(g06, albedo, floor_mix);
			nrm = mix(texture(ground_normal_tex, uv).rgb, nrm, floor_mix);
			arm = mix(texture(ground_arm_tex, uv).rgb, arm, floor_mix);
		}
		if (use_grass_layer) {
			// Sharpen the noise into grass patches with soft borders.
			float g = smoothstep(0.36, 0.52, mask.r);
			vec3 g_albedo = mix(texture(grass_albedo_tex, uv).rgb,
					texture(grass_albedo_tex, uv_macro).rgb, 0.3) * grass_tint;
			albedo = mix(albedo, g_albedo, g);
			nrm = mix(nrm, texture(grass_normal_tex, uv).rgb, g);
			arm = mix(arm, texture(grass_arm_tex, uv).rgb, g);
		}
		if (use_ground_layers) {
			float p = mask.g;
			albedo = mix(albedo, texture(pebble_albedo_tex, uv).rgb, p);
			nrm = mix(nrm, texture(pebble_normal_tex, uv).rgb, p);
			arm = mix(arm, texture(pebble_arm_tex, uv).rgb, p);
		}
		ALBEDO = albedo;
		NORMAL_MAP = nrm;
		NORMAL_MAP_DEPTH = 1.0;
		AO = arm.r;
		AO_LIGHT_AFFECT = 0.4;
		ROUGHNESS = arm.g;
		METALLIC = arm.b;
	} else {
		ALBEDO = fallback_color;
		ROUGHNESS = 0.95;
	}
}
