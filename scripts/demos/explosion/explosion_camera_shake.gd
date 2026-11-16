class_name ExplosionCameraShake extends RefCounted

const SOUND_SPEED_MPS := 343.0
const MAX_ANGLE_DEG := 1.0
const DECAY_S := 0.8
## Distance, in blast radii, at which a blast shakes the camera at half its close-range strength.
const REACH_BLAST_RADII := 4.0
## Blast radius past which a bigger blast shakes no further: the rumble stays light at any size.
const REACH_MAX_BLAST_M := 1200.0
const SIZE_BASE := 0.5
const SIZE_PER_M := 0.025
const FREQUENCIES_HZ: Array[float] = [23.0, 31.0, 17.0]

var camera: Camera3D

var _trauma := 0.0
var _time_s := 0.0
var _pending: Array[Vector2] = []
var _phases := Vector3(0.0, 2.1, 4.3)
var _baseline := Vector3.ZERO


## Trauma one blast adds at [param distance_m] from the camera, in [0, 1].
static func trauma_for(charge: ExplosionCharge, distance_m: float) -> float:
	var size := clampf(SIZE_BASE + SIZE_PER_M * charge.radius_m, SIZE_BASE, 1.0)
	var reach_m := minf(charge.blast_radius_m, REACH_MAX_BLAST_M) * REACH_BLAST_RADII
	return clampf(size / (1.0 + pow(distance_m / reach_m, 2.0)), 0.0, 1.0)


static func onset_s(distance_m: float) -> float:
	return distance_m / SOUND_SPEED_MPS


func on_detonated(origin: Vector3, charge: ExplosionCharge, _carry_velocity: Vector3) -> void:
	if camera == null:
		return
	var distance_m := camera.global_position.distance_to(origin)
	_pending.append(Vector2(_time_s + onset_s(distance_m), trauma_for(charge, distance_m)))


func active() -> bool:
	return _trauma > 0.0 or not _pending.is_empty()


## [param delta] is game time: pause freezes the shake and the shock delay together.
func update(delta: float) -> void:
	if camera == null or not active():
		return
	if _trauma <= 0.0:
		_baseline = camera.rotation
	_time_s += delta
	var arrived := false
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i].x <= _time_s:
			_trauma = minf(_trauma + _pending[i].y, 1.0)
			_pending.remove_at(i)
			arrived = true
	if _trauma <= 0.0:
		return
	if not arrived:
		_trauma = maxf(_trauma - delta / DECAY_S, 0.0)
	if _trauma <= 0.0:
		camera.rotation = _baseline
		return
	var amplitude := deg_to_rad(MAX_ANGLE_DEG) * pow(_trauma, 1.5)
	camera.rotation = _baseline + amplitude * Vector3(
		sin(_time_s * TAU * FREQUENCIES_HZ[0] + _phases.x),
		sin(_time_s * TAU * FREQUENCIES_HZ[1] + _phases.y),
		0.5 * sin(_time_s * TAU * FREQUENCIES_HZ[2] + _phases.z))


func stop() -> void:
	if _trauma > 0.0 and is_instance_valid(camera):
		camera.rotation = _baseline
	_trauma = 0.0
	_pending.clear()
