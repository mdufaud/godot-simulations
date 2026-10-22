class_name SmokeEmitter extends Resource
## One soft ellipsoid that adds smoke, heat and momentum to the grid. A fan is an
## emitter with velocity and no density; a pulsed emitter fires pulse_on_s every
## pulse_period_s.

@export var position_m := Vector3.ZERO
## Ellipsoid radii.
@export var extent_m := Vector3(0.3, 0.3, 0.3)
@export var density_per_s := 1.0
## Negative cools the air: cold smoke sinks.
@export var heat_k_per_s := 0.0
@export var velocity_mps := Vector3.ZERO
## How fast the air inside is pulled to velocity_mps; 0 leaves it alone.
@export_range(0.0, 60.0, 0.1) var relax_hz := 0.0
## 0 = continuous.
@export_range(0.0, 20.0, 0.01) var pulse_period_s := 0.0
@export_range(0.0, 20.0, 0.01) var pulse_on_s := 0.0


func validate() -> String:
	if extent_m.x <= 0.0 or extent_m.y <= 0.0 or extent_m.z <= 0.0:
		return "extent_m must be positive on every axis"
	if relax_hz < 0.0:
		return "relax_hz must not be negative"
	if pulse_period_s > 0.0 and (pulse_on_s <= 0.0 or pulse_on_s > pulse_period_s):
		return "pulse_on_s must be in (0, pulse_period_s]"
	return ""


func is_on(time_s: float) -> bool:
	return pulse_period_s <= 0.0 or fmod(maxf(time_s, 0.0), pulse_period_s) < pulse_on_s


func pack(rate_scale: float, heat_scale: float, speed_scale: float) -> PackedFloat32Array:
	return SmokeSolver.pack_source(position_m, extent_m, density_per_s * rate_scale,
		heat_k_per_s * heat_scale, velocity_mps * speed_scale, relax_hz)
