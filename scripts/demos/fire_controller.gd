extends Node3D
## Fire Demo Controller — Simulation-driven volumetric fire rendering
## Uploads the FireSimulationGrid to a Texture3D raymarched by fire.gdshader
##
## Inspired by Fire-X (Wrede et al., SIGGRAPH Asia 2025):
## Multi-species combustion with stoichiometric heat release,
## buoyancy-driven advection with vorticity confinement.

# --- Node references ---
@onready var fire_volume: MeshInstance3D = $FireVolume
@onready var spark_particles: GPUParticles3D = $SparkParticles
@onready var fire_light: OmniLight3D = $FireLight
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu

var stats_label: Label
var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar

# --- Simulation ---
const GRID_X := 16
const GRID_Y := 24
const GRID_Z := 16
const CELL_SIZE := 0.4

var sim: FireSimulationGrid
var volume_material: ShaderMaterial

# --- Volume texture upload ---
var _vol_bytes: PackedByteArray
var _vol_images: Array[Image] = []
var _vol_tex: ImageTexture3D

# --- Fire sources (continuous fuel injection points) ---
var fuel_sources: Array[Dictionary] = []

# --- Interaction state ---
var is_adding_water := false
var is_smothering := false  # Smother is sustained (hold action)
var water_position := Vector3(0, 0.5, 0)

# --- Timing ---
var sim_accumulator := 0.0
const SIM_TIMESTEP := 1.0 / 20.0  # Simulation at 20Hz (decoupled from render)
const MAX_SIM_STEPS := 2           # Cap steps per frame to avoid death spiral

# --- Worker thread (sim steps run off the main thread) ---
var _sim_task_id := -1
var _pending_cmds: Array[Callable] = []  # sim mutations deferred to between-steps


func _ready() -> void:
	sim = FireSimulationGrid.new(GRID_X, GRID_Y, GRID_Z, CELL_SIZE)

	volume_material = fire_volume.material_override as ShaderMaterial
	_setup_volume_texture()

	# Set up default fire sources
	_setup_default_fire()

	# Setup UI
	_setup_ui()

	# Configure orbit camera
	orbit_cam.target = Vector3(0, 2.6, 0)
	orbit_cam.distance = 12.5
	orbit_cam.pitch = -13.0
	orbit_cam.yaw = 30.0
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 18.0


func _process(delta: float) -> void:
	# --- Simulation step (fixed timestep, capped, on worker thread) ---
	sim_accumulator += delta
	if sim_accumulator > SIM_TIMESTEP * MAX_SIM_STEPS:
		sim_accumulator = SIM_TIMESTEP * MAX_SIM_STEPS  # Drop time instead of catching up

	if _sim_task_id != -1 and WorkerThreadPool.is_task_completed(_sim_task_id):
		WorkerThreadPool.wait_for_task_completion(_sim_task_id)
		_sim_task_id = -1
		_update_volume_texture()
		_update_ui_stats()

	if _sim_task_id == -1:
		# Sim idle: safe window to mutate its arrays
		for cmd in _pending_cmds:
			cmd.call()
		_pending_cmds.clear()
		if sim_accumulator >= SIM_TIMESTEP:
			var steps := mini(int(sim_accumulator / SIM_TIMESTEP), MAX_SIM_STEPS)
			sim_accumulator -= float(steps) * SIM_TIMESTEP
			_sim_task_id = WorkerThreadPool.add_task(_sim_steps.bind(steps), false, "fire sim")

	# --- Update visuals from simulation ---
	_update_light()

	# Sparks appear when reaction is intense
	if spark_particles:
		spark_particles.emitting = sim.max_reaction_rate_observed > 0.03


func _sim_steps(steps: int) -> void:
	for _s in steps:
		_inject_fuel_sources(SIM_TIMESTEP)

		if is_adding_water:
			sim.apply_water_at(water_position, 1.5, 2.0 * SIM_TIMESTEP)

		if is_smothering:
			sim.smother_at(Vector3.ZERO, 2.0)

		sim.step(SIM_TIMESTEP)


func _wait_for_sim() -> void:
	if _sim_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_sim_task_id)
		_sim_task_id = -1


func _exit_tree() -> void:
	_wait_for_sim()


# =========================================================================
#  VOLUME TEXTURE
# =========================================================================

func _setup_volume_texture() -> void:
	_vol_bytes = PackedByteArray()
	_vol_bytes.resize(GRID_X * GRID_Y * GRID_Z * 4)
	sim.write_volume_bytes(_vol_bytes)

	_vol_images.clear()
	var slice_size := GRID_X * GRID_Y * 4
	for z in GRID_Z:
		var slice := _vol_bytes.slice(z * slice_size, (z + 1) * slice_size)
		_vol_images.append(Image.create_from_data(GRID_X, GRID_Y, false, Image.FORMAT_RGBA8, slice))

	_vol_tex = ImageTexture3D.new()
	_vol_tex.create(Image.FORMAT_RGBA8, GRID_X, GRID_Y, GRID_Z, false, _vol_images)

	if volume_material:
		volume_material.set_shader_parameter("volume_tex", _vol_tex)
		volume_material.set_shader_parameter("box_size", Vector3(
			GRID_X * CELL_SIZE, GRID_Y * CELL_SIZE, GRID_Z * CELL_SIZE))


func _update_volume_texture() -> void:
	sim.write_volume_bytes(_vol_bytes)
	var slice_size := GRID_X * GRID_Y * 4
	for z in GRID_Z:
		var slice := _vol_bytes.slice(z * slice_size, (z + 1) * slice_size)
		_vol_images[z].set_data(GRID_X, GRID_Y, false, Image.FORMAT_RGBA8, slice)
	_vol_tex.update(_vol_images)


# =========================================================================
#  FIRE SETUP
# =========================================================================

func _setup_default_fire() -> void:
	# Central campfire-style source
	fuel_sources.append({
		"position": Vector3(0, 0.3, 0),
		"radius": 1.0,
		"rate": 2.0,  # Fuel injection rate per second (enough to survive interactions)
	})

	# Initial ignition
	sim.ignite_at(Vector3(0, 0.5, 0), 1.2, 0.9)
	sim.ignite_at(Vector3(0.3, 0.3, 0.2), 0.8, 0.7)
	sim.ignite_at(Vector3(-0.2, 0.3, -0.1), 0.8, 0.7)


func _inject_fuel_sources(dt: float) -> void:
	for source in fuel_sources:
		sim.add_fuel_at(source["position"], source["radius"], source["rate"] * dt)
		# Auto-reignition: embers persist in fuel bed.
		var t := sim.sample_temperature(source["position"])
		if t < sim.ignition_temperature + 50.0:
			var f := sim.sample_fuel(source["position"])
			if f > 0.1:
				var gc := sim.world_to_grid(source["position"])
				var i := sim.idx(gc.x, gc.y, gc.z)
				# Ember heat
				sim.temperature[i] = maxf(sim.temperature[i], sim.ignition_temperature + 80.0)


func _reset_simulation() -> void:
	_wait_for_sim()
	_pending_cmds.clear()
	sim = FireSimulationGrid.new(GRID_X, GRID_Y, GRID_Z, CELL_SIZE)
	_smooth_light_energy = 0.0
	_smooth_light_range = 8.0
	fuel_sources.clear()
	_setup_default_fire()
	_update_volume_texture()


# =========================================================================
#  LIGHT
# =========================================================================

## Dynamic fire light based on simulation temperature
var _smooth_light_energy := 0.0
var _smooth_light_range := 8.0

func _update_light() -> void:
	if not fire_light:
		return

	var dt := get_process_delta_time()
	var light_blend := clampf(3.0 * dt, 0.0, 1.0)  # Smooth light changes

	var temp_norm := clampf(
		(sim.max_temp_observed - sim.ambient_temperature) / (sim.max_temperature - sim.ambient_temperature),
		0.0, 1.0
	)

	# Target values — boosted multiplier so fire properly illuminates scene
	var target_energy := temp_norm * 8.0
	var target_range := 8.0 + temp_norm * 14.0

	# Smooth convergence
	_smooth_light_energy = lerpf(_smooth_light_energy, target_energy, light_blend)
	_smooth_light_range = lerpf(_smooth_light_range, target_range, light_blend)

	fire_light.light_energy = _smooth_light_energy
	fire_light.omni_range = _smooth_light_range

	# Light color from Planck-like mapping
	var light_color := Color(1.0, 0.55, 0.15)  # Default warm orange
	if temp_norm > 0.7:
		light_color = light_color.lerp(Color(1.0, 0.9, 0.7), (temp_norm - 0.7) / 0.3)
	elif temp_norm < 0.3:
		light_color = light_color.lerp(Color(0.8, 0.3, 0.1), 1.0 - temp_norm / 0.3)

	fire_light.light_color = light_color

	# Very gentle flicker (2% max variation)
	var flicker := 1.0 - 0.02 * sin(Time.get_ticks_msec() * 0.01) * cos(Time.get_ticks_msec() * 0.017)
	fire_light.light_energy *= flicker


# =========================================================================
#  UI
# =========================================================================

func _update_ui_stats() -> void:
	# Sample a few points in center column (reduced from 8 to 4 for perf)
	var avg_temp := 0.0
	var avg_fuel := 0.0
	var avg_oxygen := 0.0

	for y in range(0, 4):
		var pos := Vector3(0, float(y) * 0.8, 0)
		var t := sim.sample_temperature(pos)
		avg_temp = maxf(avg_temp, t)  # Use max, not average
		avg_fuel += sim.sample_fuel(pos)
		avg_oxygen += sim.sample_oxygen(pos)

	avg_fuel /= 4.0
	avg_oxygen /= 4.0

	var temp_norm := (avg_temp - sim.ambient_temperature) / (sim.max_temperature - sim.ambient_temperature)

	stats_label.text = "T: %d K (%.0f%%) | Heat: %.1f" % [int(avg_temp), temp_norm * 100.0, sim.total_heat]
	fuel_bar.value = avg_fuel * 100.0
	oxygen_bar.value = avg_oxygen * 100.0
	temp_bar.value = clampf(temp_norm * 100.0, 0.0, 100.0)


func _setup_ui() -> void:
	stats_label = menu.add_label("T: 293 K | Heat: 0.0")
	menu.add_separator()
	fuel_bar = menu.add_progress_bar("Fuel", 100.0)
	oxygen_bar = menu.add_progress_bar("Oxygen", 100.0)
	temp_bar = menu.add_progress_bar("Temperature", 100.0)

	menu.add_separator()
	menu.add_section("Actions")
	menu.add_button("Reset", _reset_simulation)
	menu.add_button("Add Fuel", func() -> void:
		_pending_cmds.append(func() -> void:
			sim.add_fuel_at(Vector3(0, 0.3, 0), 1.5, 0.8)
			sim.ignite_at(Vector3(0, 0.5, 0), 1.2, 0.7)))
	menu.add_toggle("Wind", false, func(on: bool) -> void:
		sim.wind = Vector3(2.0, 0.0, 0.5) if on else Vector3.ZERO)
	menu.add_toggle("Extinguish", false, func(on: bool) -> void:
		is_adding_water = on)
	menu.add_toggle("Smother", false, func(on: bool) -> void:
		is_smothering = on)

	menu.add_separator()
	menu.add_section("Parameters")
	menu.add_slider("Reaction Rate", 0.5, 10.0, sim.reaction_rate,
		func(v: float): sim.reaction_rate = v)
	menu.add_slider("Heat Release", 100.0, 8000.0, sim.heat_release,
		func(v: float): sim.heat_release = v)
	menu.add_slider("Stoichiometry", 1.0, 8.0, sim.stoichiometric_ratio,
		func(v: float): sim.stoichiometric_ratio = v)
	menu.add_slider("Buoyancy", 1.0, 15.0, sim.buoyancy_strength,
		func(v: float): sim.buoyancy_strength = v)
	menu.add_slider("Vorticity", 0.0, 6.0, sim.vorticity_epsilon,
		func(v: float): sim.vorticity_epsilon = v)
	menu.add_slider("Cooling Rate", 0.02, 1.0, sim.cooling_rate,
		func(v: float): sim.cooling_rate = v)
	menu.add_slider("Fuel Supply", 0.0, 5.0, 2.0,
		func(v: float):
			if fuel_sources.size() > 0:
				fuel_sources[0]["rate"] = v)
	menu.add_slider("Wind X", -5.0, 5.0, 0.0,
		func(v: float): sim.wind.x = v)
	menu.add_slider("Wind Z", -5.0, 5.0, 0.0,
		func(v: float): sim.wind.z = v)
