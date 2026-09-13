class_name TerrainConfig extends Resource

@export_range(16, 2048, 1) var grid_size: int = 512
@export_range(0.1, 100.0, 0.1) var world_size_m: float = 4.0
@export_range(1.0, 89.0, 0.1) var repose_angle_deg: float = 33.0
@export_range(0.001, 10.0, 0.001) var flow_rate: float = 0.11
@export_range(1, 64, 1) var flow_iterations: int = 10

@export_group("Water")
@export_range(0.01, 1.0, 0.01) var water_flow_rate: float = 0.4
@export_range(0.0, 2.0, 0.001) var erosion_rate: float = 0.15
@export_range(0.0, 10.0, 0.01) var sediment_capacity: float = 0.8
## Fraction of the exchange rate jittered per pair per frame; 0 gives straight
## channels, higher values meander.
@export_range(0.0, 0.5, 0.01) var stochasticity: float = 0.15

@export_group("Snow")
@export_range(1.0, 89.0, 0.1) var snow_repose_angle_deg: float = 50.0
@export_range(0.001, 1.0, 0.001) var snow_flow_rate: float = 0.05

@export_group("Climate")
@export_range(0.0, 1.0, 0.0001) var melt_rate_m_s: float = 0.0
@export_range(0.0, 1.0, 0.0001) var evap_rate_m_s: float = 0.02
## Uniform snow deposition per second (a weather source; adds mass).
@export_range(0.0, 1.0, 0.0001) var snowfall_rate_m_s: float = 0.0
## Standing water that freezes into snow per second (an in-cell G -> B move).
@export_range(0.0, 1.0, 0.0001) var freeze_rate_m_s: float = 0.0
## How much steeper wet sand holds at saturation (multiplier on tan(repose)).
@export_range(0.0, 3.0, 0.01) var wet_gain: float = 0.6
## Water depth at which wetness (and its cohesion gain) saturates.
@export_range(0.001, 0.5, 0.001) var water_sat_m: float = 0.04


func validate() -> String:
	if grid_size <= 0 or world_size_m <= 0.0:
		return "grid_size and world_size_m must be positive"
	if repose_angle_deg <= 0.0 or repose_angle_deg >= 90.0:
		return "repose_angle_deg must be between 0 and 90"
	if snow_repose_angle_deg <= 0.0 or snow_repose_angle_deg >= 90.0:
		return "snow_repose_angle_deg must be between 0 and 90"
	if flow_rate <= 0.0 or flow_iterations <= 0 or water_flow_rate <= 0.0 \
			or snow_flow_rate <= 0.0:
		return "flow_rate, flow_iterations, water_flow_rate and snow_flow_rate must be positive"
	if erosion_rate < 0.0 or sediment_capacity < 0.0 or stochasticity < 0.0:
		return "erosion_rate, sediment_capacity and stochasticity cannot be negative"
	if melt_rate_m_s < 0.0 or evap_rate_m_s < 0.0 or snowfall_rate_m_s < 0.0 \
			or freeze_rate_m_s < 0.0 or wet_gain < 0.0 or water_sat_m <= 0.0:
		return "climate rates cannot be negative and water_sat_m must be positive"
	return ""
