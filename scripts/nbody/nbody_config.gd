class_name NBodyConfig extends Resource

@export_range(1, 1048576, 1) var particle_count: int = 262144
@export_range(1, 1048576, 1) var self_gravity_max_particles: int = 16384
@export_range(1, 4096, 1) var texture_width: int = 512
@export var self_gravity := false
@export_range(0.0001, 1.0, 0.0001) var time_step_s: float = 0.004
@export_range(1, 32, 1) var substeps: int = 2
@export_range(0.0, 100.0, 0.01) var gravity_constant: float = 1.0
@export_range(0.0, 10.0, 0.001) var softening_m: float = 0.12
@export var force_mode: int = 0
@export_range(0.0, 100.0, 0.01) var vortex_updraft_mps: float = 2.5
@export_range(0.0, 100.0, 0.01) var vortex_swirl_mps: float = 3.5
@export_range(0.0, 100.0, 0.01) var vortex_turbulence_mps2: float = 2.5
@export_range(0.01, 120.0, 0.01) var firework_period_s: float = 20.0
@export_range(0.0, 100.0, 0.01) var firework_spread_m: float = 24.0
@export_range(0.0, 100.0, 0.01) var firework_speed_mps: float = 12.0
@export_range(0.0, 20.0, 0.01) var firework_gravity_mps2: float = 0.8
@export_range(1.0, 64.0, 1.0) var firework_rockets: float = 8.0


func validate() -> String:
	if particle_count <= 0 or texture_width <= 0:
		return "particle_count and texture_width must be positive"
	if texture_width * texture_width < particle_count:
		return "texture_width is too small for particle_count"
	if self_gravity and particle_count > self_gravity_max_particles:
		return "self-gravity supports at most %d particles" % self_gravity_max_particles
	if time_step_s <= 0.0 or substeps <= 0:
		return "time_step_s and substeps must be positive"
	return ""
