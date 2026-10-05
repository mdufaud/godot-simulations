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

float ocean_shore_weight(vec2 world, float domain) {
	vec2 edge = smoothstep(vec2(domain * 0.5 - 12.0), vec2(domain * 0.5), abs(world));
	return (1.0 - edge.x) * (1.0 - edge.y);
}

vec2 ocean_shore_weight_gradient(vec2 world, float domain) {
	vec2 t = clamp((abs(world) - vec2(domain * 0.5 - 12.0)) / 12.0, vec2(0.0), vec2(1.0));
	vec2 edge = t * t * (3.0 - 2.0 * t);
	vec2 derivative = -sign(world) * 6.0 * t * (1.0 - t) / 12.0;
	return derivative * (1.0 - edge.yx);
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
