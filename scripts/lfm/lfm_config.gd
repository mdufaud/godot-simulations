class_name LfmConfig extends Resource

enum Scenario { WIND_TUNNEL, VORTEX_RING }

@export var scenario: Scenario = Scenario.WIND_TUNNEL
@export var grid_dims: Vector3i = Vector3i(128, 64, 64)
@export var domain_size_m: Vector3 = Vector3(2.0, 1.0, 1.0)
@export var frame_dt_s: float = 1.0 / 60.0
@export var max_frame_dt_s: float = 1.0 / 30.0
@export_range(2, 10, 1) var reinit_every: int = 5
@export var map_rk4: bool = true
@export var interpolate_frames: bool = false
@export var inlet_speed_mps: float = 0.6
@export var inlet_angle_deg: float = 20.0
@export var bfecc_clamp: bool = true
@export var solid_enabled: bool = true


func validate() -> String:
	if grid_dims.x < 8 or grid_dims.y < 8 or grid_dims.z < 8:
		return "grid_dims must be at least 8 cells on each axis"
	if grid_dims.x % 8 != 0 or grid_dims.y % 8 != 0 or grid_dims.z % 8 != 0:
		return "grid_dims must be multiples of 8"
	if domain_size_m.x <= 0.0 or domain_size_m.y <= 0.0 or domain_size_m.z <= 0.0:
		return "domain_size_m must be positive"
	var h := domain_size_m.x / grid_dims.x
	if absf(domain_size_m.y / grid_dims.y - h) > h * 0.0001 \
			or absf(domain_size_m.z / grid_dims.z - h) > h * 0.0001:
		return "LFM requires cubic cells"
	if frame_dt_s <= 0.0 or max_frame_dt_s <= 0.0 \
			or reinit_every < 2 or reinit_every > 10:
		return "frame_dt_s, max_frame_dt_s or reinit_every is invalid"
	if inlet_speed_mps < 0.0:
		return "inlet_speed_mps must be nonnegative"
	return ""


func cell_size_m() -> float:
	return domain_size_m.x / grid_dims.x


func substep_dt_s() -> float:
	return frame_dt_s / reinit_every


func bounded_frame_dt_s(elapsed_s: float) -> float:
	var speed_bound_mps := maxf(inlet_speed_mps, 0.6)
	var cfl_limit_s := 0.4 * reinit_every * cell_size_m() / speed_bound_mps
	return minf(maxf(elapsed_s, 0.0), minf(max_frame_dt_s, cfl_limit_s))
