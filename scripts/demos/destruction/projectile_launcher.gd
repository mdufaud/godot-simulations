class_name ProjectileLauncher extends RefCounted
## Fires the demo's projectiles at whatever the camera is pointing at, and turns
## their impact into a blast the host applies to the walls.

## Emitted on impact, in world space. The host decides which walls it reaches.
signal impact(origin: Vector3, radius_m: float, impulse: float)

const DESPAWN_Y := -8.0
## The floor is an infinite WorldBoundary: a spent round rests on it forever
## instead of falling out of the world, so age is the real despawn bound.
const ROUND_LIFETIME_S := 20.0

var camera: Camera3D
## Projectiles are parented here, so clearing them is one subtree.
var container: Node3D
## Host multipliers on every blast, driven by the panel.
var radius_scale := 1.0
var power_scale := 1.0

var _preset: ProjectilePreset


func arm(preset: ProjectilePreset) -> void:
	var error := preset.validate()
	if error != "":
		push_error("Projectile preset '%s': %s" % [preset.display_name, error])
		return
	_preset = preset


func fire(screen_pos: Vector2) -> void:
	assert(camera != null and container != null,
		"ProjectileLauncher: camera and container must be assigned")
	if _preset == null:
		return
	var preset := _preset
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)

	var ball := RigidBody3D.new()
	ball.position = origin + dir * 0.6
	ball.mass = preset.mass_kg
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	ball.linear_velocity = dir * preset.speed_mps
	var shape := SphereShape3D.new()
	shape.radius = preset.radius_m
	var col := CollisionShape3D.new()
	col.shape = shape
	ball.add_child(col)
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = preset.radius_m
	sphere.height = preset.radius_m * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = preset.color
	mat.metallic = preset.metallic
	mat.roughness = preset.roughness
	if preset.emission != Color.BLACK:
		mat.emission_enabled = true
		mat.emission = preset.emission
	sphere.material = mat
	mi.mesh = sphere
	ball.add_child(mi)
	ball.body_entered.connect(_on_hit.bind(ball, preset), CONNECT_ONE_SHOT)
	ball.set_meta("fired_at_msec", Time.get_ticks_msec())
	container.add_child(ball)


func clear() -> void:
	for p in container.get_children():
		p.queue_free()


## Retires the rounds that missed everything or have lived out their blast
## window on the floor.
func despawn_fallen() -> void:
	var now := Time.get_ticks_msec()
	for p in container.get_children():
		if p is Node3D and (p.global_position.y < DESPAWN_Y
				or now - int(p.get_meta("fired_at_msec", now)) > ROUND_LIFETIME_S * 1000.0):
			p.queue_free()


func _on_hit(_other: Node, ball: RigidBody3D, preset: ProjectilePreset) -> void:
	# The kinetic energy the projectile actually arrives with drives the blast, so
	# a slow lob dents the wall and a full-speed shot blows a hole through it.
	var strength := clampf(ball.linear_velocity.length() / preset.speed_mps, 0.1, 1.5)
	impact.emit(ball.global_position, preset.blast_radius_m * radius_scale,
		strength * preset.blast_impulse * power_scale)
	if preset.explodes:
		_flash(ball.global_position)
		ball.queue_free()


func _flash(pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 10.0
	light.omni_range = 14.0
	container.add_child(light)
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.4)
	tween.tween_callback(light.queue_free)
