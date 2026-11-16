class_name ProjectileLauncher extends RefCounted
## Fires the demo's projectiles at whatever the camera is pointing at, and turns
## their impact into a blast the host applies to the walls.

## Emitted on impact, in world space. The host decides which walls it reaches.
signal impact(origin: Vector3, radius_m: float, impulse: float)
## Emitted once per spawned projectile, after it joined the container.
signal fired(ball: RigidBody3D, preset: ProjectilePreset)

const DESPAWN_Y := -8.0
## The floor is an infinite WorldBoundary: a spent round rests on it forever
## instead of falling out of the world, so age is the real despawn bound.
const ROUND_LIFETIME_S := 20.0
## A straight flight that never touched anything is retired beyond this distance.
const STRAIGHT_RANGE_M := 400.0

var camera: Camera3D
## Projectiles are parented here, so clearing them is one subtree.
var container: Node3D
## Host multipliers on every blast, driven by the panel.
var radius_scale := 1.0
var power_scale := 1.0
## A ball that does not explode reports every body it touches, not only the first.
var report_every_contact := false
## Velocity a straight-flight projectile carried into the contact that last emitted [signal impact].
var impact_velocity := Vector3.ZERO

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
	var velocity_dir := dir
	if preset.straight_flight and dir.y < -1e-4:
		# The ball centre reaches the aimed ground point at the height where its surface touches the ground.
		var t := (origin.y - preset.radius_m) / -dir.y
		if t > 0.0:
			velocity_dir = (origin + dir * t - (origin + dir * 0.6)).normalized()

	var ball := RigidBody3D.new()
	ball.position = origin + dir * 0.6
	ball.mass = preset.mass_kg
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	ball.linear_velocity = velocity_dir * preset.speed_mps
	if preset.straight_flight:
		ball.gravity_scale = 0.0
		ball.set_meta("launch_velocity", ball.linear_velocity)
		ball.set_meta("flying", true)
		ball.set_meta("launch_origin", ball.position)
	if not preset.collide_with_projectiles:
		for other in container.get_children():
			if other is RigidBody3D and not other.is_queued_for_deletion():
				ball.add_collision_exception_with(other)
				other.add_collision_exception_with(ball)
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
	ball.body_entered.connect(_on_hit.bind(ball, preset), 0 if report_every_contact else CONNECT_ONE_SHOT)
	ball.set_meta("fired_at_msec", Time.get_ticks_msec())
	container.add_child(ball)
	fired.emit(ball, preset)


## Straight-flight projectiles that have not touched anything yet.
func flying_count() -> int:
	var count := 0
	for p in container.get_children():
		if p.get_meta("flying", false) and not p.is_queued_for_deletion():
			count += 1
	return count


func clear() -> void:
	for p in container.get_children():
		p.queue_free()


## Retires the rounds that missed everything or have lived out their blast
## window on the floor.
func despawn_fallen() -> void:
	var now := Time.get_ticks_msec()
	for p in container.get_children():
		var lost: bool = p.get_meta("flying", false) \
			and p.global_position.distance_to(p.get_meta("launch_origin")) > STRAIGHT_RANGE_M
		if p is Node3D and (lost or p.global_position.y < DESPAWN_Y
				or now - int(p.get_meta("fired_at_msec", now)) > ROUND_LIFETIME_S * 1000.0):
			p.queue_free()


func _on_hit(_other: Node, ball: RigidBody3D, preset: ProjectilePreset) -> void:
	if ball.is_queued_for_deletion():
		return
	# The kinetic energy the projectile actually arrives with drives the blast, so
	# a slow lob dents the wall and a full-speed shot blows a hole through it.
	if ball.get_meta("flying", false):
		ball.set_meta("flying", false)
		ball.set_deferred("gravity_scale", 1.0)
		impact_velocity = ball.get_meta("launch_velocity")
	var strength := clampf(ball.linear_velocity.length() / preset.speed_mps, 0.1, 1.5)
	impact.emit(ball.global_position, preset.blast_radius_m * radius_scale,
		strength * preset.blast_impulse * power_scale)
	if preset.explodes:
		flash(ball.global_position)
		ball.queue_free()


func flash(pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 10.0
	light.omni_range = 14.0
	container.add_child(light)
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.4)
	tween.tween_callback(light.queue_free)
