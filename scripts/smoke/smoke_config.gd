class_name SmokeConfig extends Resource
## Stable-fluids smoke volume: the domain, the solver budget, the air physics and
## the look. Tier fields (Quality group) are owned by SmokeQualityProfile; a
## scene preset carries the rest.

@export_group("Domain")
@export var domain_size_m := Vector3(6.0, 9.0, 6.0)
## Corner of the domain; its y is the floor.
@export var domain_origin_m := Vector3(-3.0, 0.0, -3.0)

@export_group("Quality")
@export_range(10.0, 120.0, 1.0) var sim_rate_hz := 60.0
@export_range(4096, 4000000, 1) var grid_cell_budget := 400000
@export_range(1, 256, 1) var pressure_iterations := 24
@export_range(0.25, 2.0, 0.05) var march_step_cells := 0.75
@export_range(1, 4, 1) var light_downsample := 2
@export_range(0.25, 4.0, 0.05) var light_step_cells := 1.5
## Second-order advection: keeps vortices and thin wisps, costs two passes and
## two more fields.
@export var maccormack := true

@export_group("Air")
@export_range(0.0, 0.5, 0.001) var buoyancy_mps2_per_k := 0.04
@export_range(0.0, 5.0, 0.01) var smoke_weight_mps2 := 0.5
@export_range(0.0, 2.0, 0.001) var density_decay_hz := 0.02
@export_range(0.0, 5.0, 0.01) var temperature_decay_hz := 0.6
@export_range(0.0, 2.0, 0.001) var velocity_decay_hz := 0.05
@export_range(0.0, 2.0, 0.01) var vorticity_confinement := 0.35
@export_range(0.0, 10.0, 0.05) var wind_speed_mps := 0.0
@export_range(0.0, 360.0, 1.0) var wind_direction_deg := 0.0
@export_range(0.0, 5.0, 0.01) var wind_relax_hz := 0.25

@export_group("Look")
@export_range(0.0, 40.0, 0.1) var extinction_per_m := 6.0
@export_range(0.0, 1.0, 0.01) var scattering_albedo := 0.9
@export_range(-0.9, 0.9, 0.01) var phase_g := 0.35
@export var smoke_color := Color(0.85, 0.85, 0.88)
@export_range(0.0, 2.0, 0.01) var ambient_strength := 0.35


func validate() -> String:
	if domain_size_m.x <= 0.0 or domain_size_m.y <= 0.0 or domain_size_m.z <= 0.0:
		return "domain_size_m must be positive on every axis"
	if sim_rate_hz <= 0.0:
		return "sim_rate_hz must be positive"
	if grid_cell_budget < 4096:
		return "grid_cell_budget must be at least 4096 cells"
	var dims := grid_dims()
	if dims.x < 8 or dims.y < 8 or dims.z < 8:
		return "domain too thin for the cell budget: %s cells" % dims
	if pressure_iterations < 1:
		return "pressure_iterations must be at least 1"
	if march_step_cells <= 0.0 or light_step_cells <= 0.0:
		return "march steps must be positive"
	if light_downsample < 1 or light_downsample > 4:
		return "light_downsample must be in [1, 4]"
	if density_decay_hz < 0.0 or temperature_decay_hz < 0.0 or velocity_decay_hz < 0.0 \
			or wind_relax_hz < 0.0:
		return "decay rates must not be negative"
	if extinction_per_m < 0.0:
		return "extinction_per_m must not be negative"
	if scattering_albedo < 0.0 or scattering_albedo > 1.0:
		return "scattering_albedo must be in [0, 1]"
	if absf(phase_g) >= 1.0:
		return "phase_g must be in (-1, 1)"
	return ""


## Cubic cell edge that spends the budget on the domain volume, whatever its shape.
func cell_size_m() -> float:
	var volume := domain_size_m.x * domain_size_m.y * domain_size_m.z
	return pow(volume / float(maxi(grid_cell_budget, 1)), 1.0 / 3.0)


func grid_dims() -> Vector3i:
	var cell := cell_size_m()
	return Vector3i(
		maxi(1, roundi(domain_size_m.x / cell)),
		maxi(1, roundi(domain_size_m.y / cell)),
		maxi(1, roundi(domain_size_m.z / cell)))


## Size the grid actually covers (whole cells), from domain_origin_m.
func grid_extent_m() -> Vector3:
	return Vector3(grid_dims()) * cell_size_m()


func light_dims() -> Vector3i:
	var dims := grid_dims()
	return Vector3i(
		ceili(float(dims.x) / light_downsample),
		ceili(float(dims.y) / light_downsample),
		ceili(float(dims.z) / light_downsample))


func wind_mps() -> Vector2:
	var angle := deg_to_rad(wind_direction_deg)
	return Vector2(cos(angle), sin(angle)) * wind_speed_mps
