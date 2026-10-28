class_name SoftBodyConfig extends Resource
## Vertex block descent soft bodies: the lattice and solver budget (Quality group,
## owned by SoftBodyQualityProfile), the shared material, damping and contacts.

@export_group("Quality")
@export_range(0.02, 0.25, 0.005) var lattice_cell_m := 0.08
@export_range(1, 8, 1) var substeps := 2
@export_range(1, 32, 1) var iterations := 8
## Preset bodies plus the drop pool.
@export_range(1, 64, 1) var max_bodies := 12

@export_group("Material")
## Multiplies every body's Young's modulus.
@export_range(0.05, 20.0, 0.01, "exp") var stiffness_scale := 1.0
@export_range(0.0, 0.49, 0.01) var poisson_ratio := 0.4
@export_range(50.0, 3000.0, 1.0) var density_kg_m3 := 1000.0
## Rayleigh damping: the elastic stiffness times this, on the strain rate.
@export_range(0.0, 0.1, 0.0005) var damping_s := 0.01

@export_group("Solver")
@export_range(10.0, 240.0, 1.0) var sim_rate_hz := 60.0
@export var gravity_mps2 := Vector3(0.0, -9.8, 0.0)
## Velocity retained per 1/60 s, spread across the substeps.
@export_range(0.5, 1.0, 0.001) var velocity_retention := 0.995
## Contact penalty, in units of a vertex's own inertia (m / h²).
@export_range(1.0, 1000.0, 1.0) var contact_stiffness := 60.0
## Gap kept between two bodies' surfaces, in lattice cells.
@export_range(0.0, 1.0, 0.05) var self_contact_cells := 0.15
## Mouse spring, in units of the grabbed vertex's inertia.
@export_range(0.01, 10.0, 0.01) var grab_stiffness := 4.0
@export_range(1.0, 200.0, 1.0) var max_speed_mps := 30.0


func validate() -> String:
	if lattice_cell_m <= 0.0:
		return "lattice_cell_m must be positive"
	if substeps < 1 or iterations < 1:
		return "substeps and iterations must be at least 1"
	if max_bodies < 1:
		return "max_bodies must be at least 1"
	if stiffness_scale <= 0.0 or density_kg_m3 <= 0.0:
		return "stiffness_scale and density_kg_m3 must be positive"
	if poisson_ratio < 0.0 or poisson_ratio >= 0.5:
		return "poisson_ratio must be in [0, 0.5)"
	if damping_s < 0.0 or sim_rate_hz <= 0.0:
		return "damping_s must not be negative and sim_rate_hz must be positive"
	if velocity_retention <= 0.0 or velocity_retention > 1.0:
		return "velocity_retention must be in (0, 1]"
	if contact_stiffness <= 0.0 or self_contact_cells < 0.0 or grab_stiffness <= 0.0:
		return "contact and grab stiffness must be positive, the self-contact gap not negative"
	if max_speed_mps <= 0.0:
		return "max_speed_mps must be positive"
	return ""


## Lamé parameters (mu, lambda) of a body with this Young's modulus.
func lame(youngs_modulus_pa: float) -> Vector2:
	var e := youngs_modulus_pa * stiffness_scale
	var nu := poisson_ratio
	return Vector2(e / (2.0 * (1.0 + nu)), e * nu / ((1.0 + nu) * (1.0 - 2.0 * nu)))
