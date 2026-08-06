class_name ClothWind extends RefCounted

var speed := 9.0
var gustiness := 0.6
var turbulence := 0.3
var wander := true
var direction_rad := deg_to_rad(200.0)


func vector(time: float) -> Vector3:
	if speed <= 0.0:
		return Vector3.ZERO
	var angle := direction_rad
	if wander:
		angle += 0.8 * sin(time * 0.13) + 1.1 * sin(time * 0.047 + 1.7)
	var envelope := 1.0 + gustiness * (0.45 * sin(time * 0.5)
		+ 0.35 * sin(time * 1.13 + 2.0) + 0.2 * sin(time * 2.9 + 0.7))
	return Vector3(cos(angle), 0.0, sin(angle)) * speed * maxf(envelope, 0.0)
