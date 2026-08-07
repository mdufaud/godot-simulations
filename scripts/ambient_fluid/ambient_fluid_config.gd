class_name AmbientFluidConfig
extends Resource

@export var fluid_density_kg_m3: float = 1.204
@export var dynamic_viscosity_pa_s: float = 1.81e-5
@export_range(1.5708, 3.1416, 0.001) var separation_angle_rad: float = PI * 0.5
@export var body_density_kg_m3: float = 500.0
@export var initial_velocity_m_s: Vector3 = Vector3.ZERO
@export var initial_spin_rad_s: Vector3 = Vector3.ZERO


func validate() -> String:
	if not is_finite(fluid_density_kg_m3) or fluid_density_kg_m3 < 0.0:
		return "fluid_density_kg_m3 must be finite and non-negative"
	if not is_finite(dynamic_viscosity_pa_s) or dynamic_viscosity_pa_s < 0.0:
		return "dynamic_viscosity_pa_s must be finite and non-negative"
	if not is_finite(separation_angle_rad) or separation_angle_rad < PI * 0.5 \
		or separation_angle_rad > PI:
		return "separation_angle_rad must be finite in [PI/2, PI]"
	if not is_finite(body_density_kg_m3) or body_density_kg_m3 <= 0.0:
		return "body_density_kg_m3 must be finite and positive"
	if not _finite_vector(initial_velocity_m_s):
		return "initial_velocity_m_s must be finite"
	if not _finite_vector(initial_spin_rad_s):
		return "initial_spin_rad_s must be finite"
	return ""


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
