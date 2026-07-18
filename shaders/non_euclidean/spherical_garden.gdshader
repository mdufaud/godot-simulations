shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

varying vec3 sphere_position;

void vertex() {
	sphere_position = VERTEX;
}

void fragment() {
	vec3 direction = normalize(sphere_position);
	float longitude = atan(direction.z, direction.x);
	float latitude = asin(direction.y);
	float longitude_joint = 1.0 - smoothstep(0.018, 0.055, abs(sin(longitude * 12.0)));
	float latitude_joint = 1.0 - smoothstep(0.018, 0.055, abs(sin(latitude * 12.0)));
	float joint = max(longitude_joint, latitude_joint);
	float variation = sin(longitude * 17.0 + latitude * 23.0) * 0.012;
	vec3 panel_color = vec3(0.055, 0.12, 0.16) + variation;
	vec3 joint_color = vec3(0.09, 0.38, 0.46);
	ALBEDO = mix(panel_color, joint_color, joint * 0.72);
	EMISSION = vec3(0.01, 0.035, 0.045) + vec3(0.03, 0.26, 0.34) * joint;
	ROUGHNESS = 0.86;
	METALLIC = 0.08;
}
