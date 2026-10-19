float ocean_minimum_stretch(vec3 strain) {
	return 1.0 + 0.5 * (strain.x + strain.y
		- sqrt(max((strain.x - strain.y) * (strain.x - strain.y)
			+ 4.0 * strain.z * strain.z, 0.0)));
}

float ocean_breaking_source(sampler2DArray fields, vec3 tiles, vec2 position,
		float onset, int cascade_mask) {
	vec3 strain = vec3(0.0);
	for (int cascade = 0; cascade < 3; cascade++) {
		if ((cascade_mask & (1 << cascade)) != 0) {
			float tile = cascade == 0 ? tiles.x : (cascade == 1 ? tiles.y : tiles.z);
			strain += textureLod(fields, vec3(position / tile, float(cascade)), 0.0).xyz;
		}
	}
	return clamp(1.0 - ocean_minimum_stretch(strain) / max(onset, 1e-6), 0.0, 1.0);
}

vec2 ocean_world_gradient(vec3 strain, vec2 height_gradient, float minimum_determinant) {
	float a = 1.0 + strain.x;
	float b = 1.0 + strain.y;
	float c = strain.z;
	float determinant = a * b - c * c;
	float safe_determinant = (determinant < 0.0 ? -1.0 : 1.0)
		* max(abs(determinant), minimum_determinant);
	return vec2(b * height_gradient.x - c * height_gradient.y,
		a * height_gradient.y - c * height_gradient.x) / safe_determinant;
}

vec4 ocean_local_sample(sampler2D field, vec2 center, float domain, vec2 world) {
	vec2 uv = (world - center) / domain + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec4(0.0);
	}
	return textureLod(field, uv, 0.0);
}

float ocean_shore_weight(vec2 world, float domain, float width) {
	float t = clamp((length(world) - domain * 0.5 + width) / width, 0.0, 1.0);
	return 1.0 - t * t * (3.0 - 2.0 * t);
}

vec2 ocean_shore_weight_gradient(vec2 world, float domain, float width) {
	float radius = length(world);
	float t = clamp((radius - domain * 0.5 + width) / width, 0.0, 1.0);
	return -world / max(radius, 1e-6) * (6.0 * t * (1.0 - t) / width);
}

float ocean_shore_surface_weight(sampler2D field, vec2 world, float domain, float width, vec2 depth_blend) {
	float weight = ocean_shore_weight(world, domain, width);
	if (weight <= 0.0 || depth_blend.y <= depth_blend.x) { return weight; }
	vec4 shore = ocean_local_sample(field, vec2(0.0), domain, world);
	return weight * (1.0 - smoothstep(depth_blend.x, depth_blend.y, shore.w - shore.x));
}

vec2 ocean_shore_surface_weight_gradient(sampler2D field, vec2 world, float domain, float width, vec2 depth_blend) {
	if (depth_blend.y <= depth_blend.x) { return ocean_shore_weight_gradient(world, domain, width); }
	float epsilon = domain / float(textureSize(field, 0).x);
	return vec2(ocean_shore_surface_weight(field, world + vec2(epsilon, 0.0), domain, width, depth_blend)
		- ocean_shore_surface_weight(field, world - vec2(epsilon, 0.0), domain, width, depth_blend),
		ocean_shore_surface_weight(field, world + vec2(0.0, epsilon), domain, width, depth_blend)
		- ocean_shore_surface_weight(field, world - vec2(0.0, epsilon), domain, width, depth_blend)) / (2.0 * epsilon);
}

vec2 ocean_shore_gradient(sampler2D field, vec2 world, float domain) {
	float epsilon = domain / float(textureSize(field, 0).x);
	vec4 center = ocean_local_sample(field, vec2(0.0), domain, world);
	vec4 left = ocean_local_sample(field, vec2(0.0), domain, world - vec2(epsilon, 0.0));
	vec4 right = ocean_local_sample(field, vec2(0.0), domain, world + vec2(epsilon, 0.0));
	vec4 back = ocean_local_sample(field, vec2(0.0), domain, world - vec2(0.0, epsilon));
	vec4 front = ocean_local_sample(field, vec2(0.0), domain, world + vec2(0.0, epsilon));
	return vec2((right.w > 0.002 ? right.x : center.x) - (left.w > 0.002 ? left.x : center.x),
		(front.w > 0.002 ? front.x : center.x) - (back.w > 0.002 ? back.x : center.x)) / (2.0 * epsilon);
}

vec4 ocean_shore_roll(sampler2D field, vec2 world, float domain) {
	vec2 uv = world / domain + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { return vec4(0.0); }
	vec2 size = vec2(textureSize(field, 0));
	vec2 grid = uv * size - 0.5;
	vec2 f = fract(grid);
	vec2 w0 = pow(vec2(1.0) - f, vec2(3.0)) / 6.0;
	vec2 w1 = (3.0 * f * f * f - 6.0 * f * f + 4.0) / 6.0;
	vec2 w2 = (-3.0 * f * f * f + 3.0 * f * f + 3.0 * f + 1.0) / 6.0;
	vec2 w3 = f * f * f / 6.0;
	vec2 a = w0 + w1;
	vec2 b = w2 + w3;
	vec2 low = (floor(grid) - 1.0 + w1 / a + 0.5) / size;
	vec2 high = (floor(grid) + 1.0 + w3 / b + 0.5) / size;
	return textureLod(field, low, 0.0) * a.x * a.y
		+ textureLod(field, vec2(high.x, low.y), 0.0) * b.x * a.y
		+ textureLod(field, vec2(low.x, high.y), 0.0) * a.x * b.y
		+ textureLod(field, high, 0.0) * b.x * b.y;
}

mat2 ocean_shore_jacobian(vec3 strain, vec2 displacement, float weight, vec2 weight_gradient) {
	float fade = 1.0 - weight;
	return mat2(vec2(1.0 + strain.x * fade, strain.z * fade) - displacement * weight_gradient.x,
		vec2(strain.z * fade, 1.0 + strain.y * fade) - displacement * weight_gradient.y);
}

vec2 ocean_shore_world_gradient(mat2 jacobian, vec2 material_gradient) {
	float determinant = jacobian[0].x * jacobian[1].y - jacobian[1].x * jacobian[0].y;
	float safe_determinant = (determinant < 0.0 ? -1.0 : 1.0) * max(abs(determinant), 0.0001);
	return vec2(jacobian[1].y * material_gradient.x - jacobian[0].y * material_gradient.y,
		-jacobian[1].x * material_gradient.x + jacobian[0].x * material_gradient.y) / safe_determinant;
}
