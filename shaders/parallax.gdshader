shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ──────────────────────────────────────────────────
// Contact Refinement Parallax Occlusion Mapping
// with per-light self-shadowing
//
// Based on:
// - CRPOM by LiveTrower (godotshaders.com/shader/contact-refinement-parallax-mapping/)
//   adapted from O3DE's implementation of Andrea Riccardi's technique
// - POM self-shadowing by LiveTrower (godotshaders.com/shader/parallax-occlusion-mapping-with-self-shadowing/)
// - Godot Engine built-in StandardMaterial3D heightmap implementation
// ──────────────────────────────────────────────────

// Textures
group_uniforms Textures;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_height : hint_default_black, filter_linear_mipmap, repeat_enable;

// Parallax settings
group_uniforms Parallax;
uniform float height_scale : hint_range(0.0, 0.5, 0.005) = 0.08;
uniform int min_layers : hint_range(4, 64) = 8;
uniform int max_layers : hint_range(8, 128) = 32;

// Tiling
group_uniforms Tiling;
uniform float uv_scale : hint_range(0.5, 10.0, 0.1) = 2.0;

// Material
group_uniforms Material;
uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform float specular : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;

// Lighting & Shadows
group_uniforms Lighting;
uniform float ao_strength : hint_range(0.0, 1.0, 0.05) = 0.4;
uniform bool self_shadow_enabled = true;
uniform float shadow_strength : hint_range(0.0, 2.0, 0.05) = 0.8;
uniform int shadow_layers : hint_range(4, 32) = 16;

// Computed normals from heightmap
group_uniforms Advanced;
uniform bool use_computed_normals = false;

// Shared between fragment() and light()
varying vec2 base_uv;
varying mat3 v_tbn;

void vertex() {
	UV = UV * uv_scale;
}

// ─── PBR Functions ───────────────────────────────
// Required because defining light() disables Godot's built-in diffuse/specular.
// Reimplemented to match Godot's scene_forward_lights_inc.glsl.
// See: github.com/godotengine/godot/blob/master/servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl

float D_GGX(float cos_theta_m, float alpha) {
	float a = cos_theta_m * alpha;
	float k = alpha / (1.0 - cos_theta_m * cos_theta_m + a * a);
	return k * k * (1.0 / PI);
}

// From Earl Hammon, Jr. "PBR Diffuse Lighting for GGX+Smith Microsurfaces"
float V_GGX(float NdotL, float NdotV, float alpha) {
	return 0.5 / mix(2.0 * NdotL * NdotV, NdotL + NdotV, alpha);
}

float SchlickFresnel(float u) {
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m; // pow(m, 5)
}

vec3 F0(float mt, float spc, vec3 cl) {
	float dielectric = 0.16 * spc * spc;
	// Use albedo * metallic as colored specular reflectance at 0 angle for metallic materials
	// See: google.github.io/filament/Filament.md.html
	return mix(vec3(dielectric), cl.rgb, vec3(mt));
}

// ─── Self-Shadow Ray Trace ───────────────────────
// Traces from the displaced UV toward the light through the heightmap.
// Returns 0.0 = shadowed (intersection found), 1.0 = lit (no intersection).
// Adapted from: stackoverflow.com/questions/55089830/adding-shadows-to-parallax-occlusion-map
float GetParallaxShadow(vec2 texCoord, vec3 lightDir) {
	// lightDir.z < 0 means light is above surface in tangent space (normal case)
	// lightDir.z >= 0 means light is below surface -> fully shadowed
	if (lightDir.z >= 0.0)
		return 0.0;

	float numLayers = float(shadow_layers);
	vec2 currentTexCoords = texCoord;
	float currentDepthMapValue = 1.0 - texture(texture_height, currentTexCoords).r;
	float currentLayerDepth = currentDepthMapValue;

	float layerDepth = 1.0 / numLayers;
	vec2 P = lightDir.xy / lightDir.z * height_scale;
	vec2 deltaTexCoords = P / numLayers;

	// March from surface toward the light, checking for intersections
	for (int i = 0; i < 32; i++) {
		if (currentLayerDepth > currentDepthMapValue || currentLayerDepth <= 0.0) break;
		currentTexCoords += deltaTexCoords;
		currentDepthMapValue = 1.0 - texture(texture_height, currentTexCoords).r;
		currentLayerDepth -= layerDepth;
	}

	// If ray ended above surface (intersection found), it's in shadow
	float r = currentLayerDepth > currentDepthMapValue ? 0.0 : 1.0;
	return r;
}

// ─── Heightmap-derived Normal (Central Difference) ──
vec3 compute_normal_from_height(vec2 uv, float scale) {
	float texel = 1.0 / 1024.0;
	float h_l = texture(texture_height, uv + vec2(-texel, 0.0)).r;
	float h_r = texture(texture_height, uv + vec2( texel, 0.0)).r;
	float h_d = texture(texture_height, uv + vec2(0.0, -texel)).r;
	float h_u = texture(texture_height, uv + vec2(0.0,  texel)).r;

	vec3 n;
	n.x = (h_l - h_r) * scale;
	n.y = (h_d - h_u) * scale;
	n.z = 1.0;
	return normalize(n);
}

void fragment() {
	base_uv = UV;

	// ── View direction in tangent space ──
	// Uses Godot's canonical construction from StandardMaterial3D:
	// - normalize(-VERTEX + EYE_OFFSET) is the camera-to-fragment direction in view space
	// - mat3(TANGENT, -BINORMAL, NORMAL) transforms to tangent space
	// - -BINORMAL because Godot uses mikktspace (binormal is pre-negated)
	vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET) * mat3(TANGENT, -BINORMAL, NORMAL));

	// Adaptive layer count: more layers at grazing angles for better quality
	float num_layers_f = mix(float(max_layers), float(min_layers), abs(dot(vec3(0.0, 0.0, 1.0), view_dir)));
	int num_layers_i = int(num_layers_f);
	float layer_depth = 1.0 / num_layers_f;

	// UV displacement per step
	vec2 P = view_dir.xy / view_dir.z * height_scale;
	vec2 delta = P / num_layers_f;

	// ── Pass 1: Coarse Steep Parallax March ──
	// Depth convention: 1.0-h means white(1.0) in heightmap = elevated, black(0.0) = deep
	vec2 ofs = base_uv;
	float depth = 1.0 - texture(texture_height, ofs).r;
	float current_depth = 0.0;
	float prev_depth_sample = depth;

	for (int i = 0; i < 128; i++) {
		if (i >= num_layers_i || current_depth >= depth) break;
		prev_depth_sample = depth;
		ofs -= delta;
		depth = 1.0 - texture(texture_height, ofs).r;
		current_depth += layer_depth;
	}

	// ── Pass 2: Contact Refinement ──
	// Andrea Riccardi's technique: roll back one coarse step, then subdivide
	// that single step into N refined sub-steps -> 1/(N^2) error with 2N total steps
	if (current_depth > 0.0) {
		ofs += delta;
		current_depth -= layer_depth;
		depth = prev_depth_sample;

		// Subdivide: each refined step is 1/N of the coarse step
		vec2 refined_delta = delta / num_layers_f;
		float refined_depth = layer_depth / num_layers_f;

		for (int i = 0; i < 128; i++) {
			if (i >= num_layers_i || current_depth >= depth) break;
			ofs -= refined_delta;
			depth = 1.0 - texture(texture_height, ofs).r;
			current_depth += refined_depth;
		}
	}

	// ── POM Interpolation ──
	// Linear interpolation between last two samples for sub-step accuracy
	vec2 refined_delta_interp = delta / num_layers_f;
	float refined_depth_interp = layer_depth / num_layers_f;
	vec2 prev_ofs = ofs + refined_delta_interp;
	float after_depth = depth - current_depth;
	float before_depth = (1.0 - texture(texture_height, prev_ofs).r) - current_depth + refined_depth_interp;
	float weight = after_depth / (after_depth - before_depth);
	ofs = mix(ofs, prev_ofs, weight);

	base_uv = ofs;

	// ── Sample textures at displaced UVs ──
	vec4 albedo_tex = texture(texture_albedo, base_uv);
	ALBEDO = albedo_tint.rgb * albedo_tex.rgb;

	// ── Normal mapping ──
	if (use_computed_normals) {
		vec3 cn = compute_normal_from_height(base_uv, height_scale * normal_strength * 40.0);
		NORMAL_MAP = cn * 0.5 + 0.5;
		NORMAL_MAP_DEPTH = 1.0;
	} else {
		NORMAL_MAP = texture(texture_normal, base_uv).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}

	// ── Material properties ──
	ROUGHNESS = roughness;
	SPECULAR = specular;
	METALLIC = metallic;

	// ── Height-based ambient occlusion ──
	float h = texture(texture_height, base_uv).r;
	AO = mix(1.0, h, ao_strength);
	AO_LIGHT_AFFECT = 0.5;

	// ── Store TBN for light() ──
	v_tbn = mat3(TANGENT, -BINORMAL, NORMAL);
}

void light() {
	vec3 L = normalize(LIGHT);
	vec3 N = normalize(NORMAL);
	vec3 V = normalize(VIEW);
	vec3 H = normalize(V + L);

	float NdotL = min(dot(N, L), 1.0);
	float cNdotL = max(NdotL, 0.0);
	float NdotV = dot(N, V);
	float cNdotV = max(NdotV, 1e-4);
	float cLdotH = clamp(dot(L, H), 0.0, 1.0);
	float cNdotH = clamp(dot(N, H), 0.0, 1.0);

	// ── Per-light self-shadow ──
	float shadow_factor = 1.0;
	if (self_shadow_enabled) {
		// Transform light direction to tangent space via stored TBN
		// -L = direction FROM light TO surface (needed for shadow ray trace)
		vec3 light_dir_ts = -L * v_tbn;
		float shadow = GetParallaxShadow(base_uv, light_dir_ts);
		// shadow: 0.0 = blocked, 1.0 = lit
		shadow_factor = mix(1.0, shadow, shadow_strength);
	}

	// ── Diffuse (Lambert) ──
	float diffuse_brdf_NL = cNdotL * (1.0 / PI);
	DIFFUSE_LIGHT += diffuse_brdf_NL * shadow_factor * LIGHT_COLOR * ATTENUATION;

	// ── Specular (SchlickGGX) ──
	// Roughness must be squared for microfacet alpha (per Godot convention).
	// Skip at roughness 0 to avoid sparkle artifacts.
	if (ROUGHNESS > 0.0) {
		float alpha_ggx = ROUGHNESS * ROUGHNESS;
		float D = D_GGX(cNdotH, alpha_ggx);
		float G = V_GGX(cNdotL, cNdotV, alpha_ggx);
		float cLdotH5 = SchlickFresnel(cLdotH);
		// Godot passes 1.0 as specular intensity when computing f0 in light evaluation
		vec3 f0 = F0(METALLIC, 1.0, ALBEDO);
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), METALLIC, 1.0);
		vec3 F = f0 + (f90 - f0) * cLdotH5;
		vec3 specular_brdf_NL = cNdotL * D * F * G;
		SPECULAR_LIGHT += specular_brdf_NL * LIGHT_COLOR * SPECULAR_AMOUNT * ATTENUATION;
	}
}
