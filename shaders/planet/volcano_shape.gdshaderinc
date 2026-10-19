vec4 volcano_sample(vec3 direction, vec4 volcano, float size, float height,
		float radial, float floor_fraction, float crater_bottom, float crater_top) {
	vec3 axis = normalize(volcano.xyz);
	if (dot(direction, axis) <= 0.0) {
		return vec4(volcano.w, 2.0, volcano.w + height * floor_fraction, 1.0);
	}
	vec3 tangent = cross(axis, vec3(0.0, 1.0, 0.0));
	if (dot(tangent, tangent) < 0.01) {
		tangent = cross(axis, vec3(1.0, 0.0, 0.0));
	}
	tangent = normalize(tangent);
	vec3 bitangent = normalize(cross(axis, tangent));
	float phase = dot(axis, vec3(13.1, 27.7, 43.3)) + volcano.w * 2.7;
	vec2 point = vec2(dot(direction, tangent), dot(direction, bitangent)) / size;
	float aspect = 1.0 + 0.16 * sin(phase);
	point *= vec2(aspect, 1.0 / aspect);
	float distance = length(point);
	if (distance > 1.5) {
		return vec4(volcano.w, 2.0, volcano.w + height * floor_fraction, 1.0);
	}
	float angle = atan(point.y, point.x + 1e-7);
	float flank = smoothstep(0.10, 0.30, distance);
	float outline = 1.0 + flank * (0.10 * sin(angle * 3.0 + phase)
			+ 0.07 * snoise(vec3(point * 2.3, phase)));
	float u = distance * outline;
	float flow = 0.5 + 0.5 * sin(angle * (8.0 + floor(mod(abs(phase), 4.0))) + phase
			+ u * 1.4 + snoise(vec3(point * 2.0, phase + 8.0)) * 0.9);
	float ravines = pow(flow, 8.0) * 0.23 * flank * (1.0 - smoothstep(0.78, 1.0, u));
	float summit = pow(max(1.0 - u, 0.0), 1.45)
			* (1.0 - ravines + snoise(vec3(point * 4.0, phase)) * 0.06 * flank);
	float apron = 0.055 * exp(-pow((u - 0.83) / 0.17, 2.0));
	float caldera = smoothstep(-0.25, 0.55, sin(phase * 1.37));
	float old_rim = 0.42 * exp(-pow((u - 0.68) / 0.15, 2.0))
			* smoothstep(-0.45, 0.05, sin(angle + phase)) * caldera;
	float top = volcano.w + height * clamp(max(summit, max(apron, old_rim)), 0.0, 1.0);
	float floor_radius = volcano.w + height * floor_fraction;
	float crater_width = mix(crater_bottom, crater_top, smoothstep(floor_radius, volcano.w + height, radial));
	float rim_shape = 1.0 + 0.12 * sin(angle * 3.0 + phase)
			+ 0.10 * snoise(vec3(point * 5.0, phase + 3.0));
	float crater = (distance / rim_shape - crater_width) * size;
	return vec4(top, u, floor_radius, crater);
}
