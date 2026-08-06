extends Node3D
## Fire Demo Controller — Fire-X combustion, volumetrically raymarched.
##
## The solver lives entirely in RenderingDevice textures (see FireGpuSolver);
## this node owns the frame order — emitters, then the grid step, then the water —
## and hands the rest to the demo helpers in scripts/demos/fire/: FirePresentation
## (volume + water surface), FireInteraction (weapons), FireMenu (UI), FireHud
## (debug overlay) and FireQuality (performance ladder).
##
## Fire-X: Wrede et al., ACM TOG 44(6) art. 268 (SIGGRAPH Asia 2025).
##
## The campfire scene stays visible while fuel switches between the central gas
## pipe and the wood bed. Water leaves the held weapon and is aimed by looking.

# --- Node references ---
@onready var fire_volume: MeshInstance3D = $FireVolume
@onready var spark_particles: GPUParticles3D = $SparkParticles
@onready var fire_light: OmniLight3D = $FireLight
@onready var player: FpsWalker = $Player
@onready var weapons: FireWeapons = $Player/Camera3D/Weapons
@onready var gas_pipe: Node3D = $Campfire/GasPipe
@onready var wood_pile: WoodPile = $Campfire/WoodPile
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI
@onready var viewport_guard := ViewportGuard.attach(self)

var solver: FireGpuSolver
var config: FireConfig = FireConfig.new()
var water: FireWater
var presentation: FirePresentation
var interaction: FireInteraction
var quality: FireQuality
var hud: FireHud
var menu_builder: FireMenu

var debug_info := true
var _frame_ms := 0.0

# --- Fuel mode ---
var gas_mode := true
var gas_reinjection_enabled := true
const CAMPFIRE_SPAWN := Vector3(0.0, 1.2, 4.0)
var _gas_fuel_index := 0

# --- Grid emitter (Fire-X Tab. 3 "Grid Emitter Parameter") — gas mode ---
var emitter_position := Vector3(0, 0.3, 0)
var emitter_radius := 0.8
## Fuel mass fraction injected per simulated second (NON-PAPER: Tab. 3 gives an
## emitter mass fraction, not a rate). A diffusion flame is mixing limited, so
## this has to stay below what the entrained oxygen can burn — flooding the
## domain with fuel gives a fuel-rich core that just accumulates heat.
##
## PROVISIONAL. Chosen so the burner-region fuel peaks near stoichiometric
## propane (Y_fuel = 0.06); measured peak 0.052. The flame still puff-cycles with
## a large amplitude at every rate tried (0.2-0.5), because oxygen entrainment is
## limited by a pressure projection whose gradient is not the adjoint of its
## divergence. Retune after the MAC rewrite, not before.
var emitter_rate := 0.2

# --- Water simulation budget, pushed into the render-thread closure each frame ---
var water_particle_cap := 16384
var water_substeps := 16
var water_adaptive_substeps := false

# --- Wood bed ---
## Starting heap, as (radius, angle, tilt) around the hearth: a tight core of
## three with an outer ring, so the outer logs have to be heated by the core
## before they contribute anything.
const STARTING_LOGS := [
	[0.10, 0.0, 0.10], [0.12, 2.1, -0.08], [0.11, 4.2, 0.12],
	[0.26, 1.0, 0.05], [0.26, 3.1, -0.05], [0.26, 5.2, 0.08],
]
var _log_cooldown := 0.0

## The toggle gates the sliders rather than writing the wind itself, so turning
## it off stays off no matter where the sliders sit.
var wind_vector := Vector3(2.0, 0.0, 0.5)
var _wind_enabled := false


func _ready() -> void:
	solver = FireGpuSolver.new()
	solver.config = config
	water_particle_cap = config.water_particle_count
	solver.profiling = debug_info
	RenderingServer.call_on_render_thread(solver.init_render)

	# P3/P4: SPH water droplets and their coupling to the grid. The screen-space
	# surface only reconstructs where droplets pack tight, so the budget is large
	# enough to keep both a dense in-flight column and a connected floor puddle
	# alive at once — a smaller budget starves the stream into falling beads.
	water = FireWater.new()
	water.particle_count = config.water_particle_count
	water.evaporation_active = solver.evaporation_enabled
	water.drain_rate = solver.liquid_drain_rate
	water.profiling = debug_info
	# Queued as a closure rather than bound: the pool's indirection volume does not
	# exist until the solver's own queued init_render has run on the render thread,
	# so binding it here would capture an invalid RID. The droplets keep the dense
	# box as their own SPH domain either way — only the fire grid became the map.
	var sph_box := Vector3(solver.grid_dims) * solver.cell_size
	RenderingServer.call_on_render_thread(func() -> void:
		water.init_render(solver.sim_dims(), solver.cell_size,
			solver.indirection_rid(), sph_box))

	presentation = FirePresentation.new()
	presentation.solver = solver
	presentation.water = water
	presentation.fire_volume = fire_volume
	presentation.camera = player.get_camera()
	presentation.fire_light = fire_light
	presentation.sparks = spark_particles
	add_child(presentation)
	presentation.start()

	interaction = FireInteraction.new()
	interaction.player = player
	interaction.weapons = weapons
	interaction.solver = solver
	interaction.water = water
	interaction.presentation = presentation
	interaction.set_particle_cap(water_particle_cap)

	quality = FireQuality.new()
	hud = FireHud.new()
	hud.solver = solver
	hud.water = water
	hud.build(ui_layer)

	menu_builder = FireMenu.new()
	menu_builder.build(self)

	_build_wood_bed()
	set_fuel_mode(false)


func _process(delta: float) -> void:
	_frame_ms = delta * 1000.0 if _frame_ms == 0.0 else lerpf(
		_frame_ms, delta * 1000.0, 0.1)
	quality.frame_ms = _frame_ms
	quality.update(delta)
	menu_builder.preset_status_label.text = quality.status_text()
	if not solver.initialized:
		hud.update(_frame_ms, quality.status_text(), presentation.temporal_interpolation)
		return
	presentation.update_volume()

	# Last frame's reduction, read up front: the wood bed is driven by the per-log
	# gas temperatures in it, and its emitters have to be uploaded before the
	# solver steps.
	var stats := solver.get_stats()
	interaction.update(delta, gas_mode)
	var step_count := solver.schedule_steps(delta)
	var run_fire := step_count > 0
	var sim_dt := float(step_count) * solver.timestep
	presentation.refresh_temporal_blend()
	if run_fire:
		if gas_mode:
			if gas_reinjection_enabled:
				solver.push_event(FireGpuSolver.EVENT_FUEL, emitter_position,
					emitter_radius, emitter_rate * sim_dt)
		else:
			# The bed runs on the solver's clock like everything else, and hands over
			# the whole emitter table at once. It is a solid rather than a field the
			# solver substeps, but its coupling to the gas is a rate per SIMULATED
			# second: on the wall clock it lost mass the emitter never injected —
			# 73 % of it at 32 fps, measured — so the pile emptied faster the worse
			# the frame rate got.
			wood_pile.update(sim_dt, stats["wood_temperatures"], solver.ambient_temperature)
			solver.set_wood_emitters(wood_pile.emitters())

		if interaction.is_smothering:
			solver.push_event(FireGpuSolver.EVENT_SMOTHER, Vector3.ZERO, 2.0, 20.0 * sim_dt)

	_log_cooldown = maxf(_log_cooldown - delta, 0.0)

	# P3: water particle↔grid coupling. Algorithm 1 puts the scatter and the gather
	# both ahead of the grid loop (lines 13-14) so the solver reads the liquid field
	# built this frame, and the return after it (lines 23-24).
	var liquid_scal := solver.get_liquid_scal_tex_rid()
	var liquid_vel := solver.get_liquid_velocity_tex_rid()
	var water_cap := water_particle_cap
	var water_steps := water_substeps
	var water_adaptive := water_adaptive_substeps
	var emit_water := interaction.jet_enabled
	RenderingServer.call_on_render_thread(func() -> void:
		if run_fire:
			solver.capture_interpolation_state_render()
			solver.prepare_topology_render()
		else:
			solver.poll_render()
		if water.initialized:
			water.sph.substeps = water_steps
			water.sph.max_substeps = water_steps
			water.sph.adaptive_substeps = water_adaptive
			water.step_dt = sim_dt
			water.set_particle_cap(water_cap)
			if emit_water:
				water.emit_jet(sim_dt, delta)
			water.step_droplets(delta)
			water.scatter_render()
			water.gather_render(liquid_scal, liquid_vel)
		if run_fire:
			solver.step_render(step_count, water.initialized and water.particles_active > 0)
		if water.initialized:
			water.return_render())

	presentation.update_water_surface()
	presentation.update_half_res()
	presentation.update_effects(stats, delta)
	_update_ui_stats(stats)
	hud.update(_frame_ms, quality.status_text(), presentation.temporal_interpolation)


func _exit_tree() -> void:
	presentation.release()
	# Water first: its uniform sets bind the solver's liquid textures, and freeing
	# those first makes Godot drop the dependent sets on its own — FireWater then
	# frees RIDs that are already gone ("Attempted to free invalid ID").
	RenderingServer.call_on_render_thread(water.free_render)
	RenderingServer.call_on_render_thread(solver.free_render)


## Mouse buttons only reach here while the cursor is captured: FpsWalker consumes
## the click that recaptures it, so nothing fires on the click that hands focus
## back to the viewport.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_G:
				drop_log()


# =========================================================================
#  FUEL MODE
# =========================================================================

## Swap fuel source in place. The campfire scene and solver stay loaded.
func set_fuel_mode(use_gas: bool) -> void:
	gas_mode = use_gas
	solver.reset_clock()
	gas_pipe.visible = use_gas
	wood_pile.visible = not use_gas

	# Wood volatiles are a CO/CH4/tar mix, so the campfire runs on the methane
	# surrogate; the gas pipe uses the selected fuel.
	if use_gas:
		solver.fuel_index = _gas_fuel_index
		solver.set_wood_emitters([])
	else:
		_gas_fuel_index = solver.fuel_index
		solver.fuel_index = WoodPile.FUEL_INDEX_METHANE
		solver.set_wood_emitters(wood_pile.emitters())

	# Pitched down at the hearth: from eye height at the spawn distance the flame
	# base sits about 18 degrees below the horizon, so the fire is in frame and
	# the aim ray lands on it without the player having to look around first.
	player.set_pose(CAMPFIRE_SPAWN, 0.0, -14.0)

	RenderingServer.call_on_render_thread(solver.clear_fields)
	water.reset_droplets()
	interaction.reset()
	presentation.reset_light()
	_light_fire()
	menu_builder.refresh_fuel_mode(menu, gas_mode, gas_reinjection_enabled)
	menu_builder.sync_weapon_buttons(interaction)
	menu_builder.refresh_wood(wood_pile)


func _build_wood_bed() -> void:
	# 1.1 m floor so the per-log spheres overlap into one broad flame body that
	# wraps the whole bed rather than a thin core over each log (GAME LOOK, see
	# FLAME_BOOST). Width comes from this; FLAME_BOOST fills it.
	wood_pile.emit_radius = maxf(1.3, solver.cell_size * 2.0)
	for entry in STARTING_LOGS:
		var radius: float = entry[0]
		var angle: float = entry[1]
		wood_pile.add_log(
			Vector3(cos(angle) * radius, wood_pile.log_ground_center_y(entry[2]),
				sin(angle) * radius),
			angle, entry[2])


func drop_log() -> void:
	if gas_mode or _log_cooldown > 0.0 or wood_pile.is_full():
		return
	wood_pile.add_log_on_pile(randf() * TAU, randf_range(-0.12, 0.12))
	_log_cooldown = 0.4
	menu_builder.refresh_wood(wood_pile)


func _light_fire() -> void:
	if gas_mode:
		if gas_reinjection_enabled and emitter_rate > 0.0:
			solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)
		return
	# Kindling under the heap: the core logs start at the pyrolysis onset, so
	# the bed is alight rather than making the player wait out the ~80 s a cold
	# log needs to conduct its way there. The ignite only needs enough hot gas to
	# start the probe->pyrolysis loop; a large fuel dump here is what fired the
	# visible jet at startup, and the flame holder in fire_combustion holds the
	# reaction from then on.
	wood_pile.ignite_at(Vector3.ZERO, 0.5)
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 0.8, 0.1)


func reset_simulation() -> void:
	solver.reset_clock()
	RenderingServer.call_on_render_thread(solver.clear_fields)
	water.reset_droplets()
	RenderingServer.call_on_render_thread(water.clear_droplets)
	interaction.reset()
	menu_builder.sync_weapon_buttons(interaction)
	presentation.reset_light()
	if not gas_mode:
		wood_pile.clear()
		_build_wood_bed()
	_light_fire()
	menu_builder.refresh_wood(wood_pile)


# =========================================================================
#  MENU CALLBACKS
# =========================================================================

func set_gas_fuel(index: int) -> void:
	_gas_fuel_index = index
	solver.fuel_index = index


func set_gas_reinjection(on: bool) -> void:
	gas_reinjection_enabled = on


func ignite_gas() -> void:
	if not gas_mode:
		return
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)


func set_water_level(level: int, on: bool) -> void:
	interaction.set_water_level(level, on)
	menu_builder.sync_weapon_buttons(interaction)


func set_flamethrower(on: bool) -> void:
	# Gas mode has no torch: the pipe is the emitter.
	interaction.set_flamethrower(on and not gas_mode)
	menu_builder.sync_weapon_buttons(interaction)


func pour_water() -> void:
	interaction.pour_water()
	menu_builder.sync_weapon_buttons(interaction)


func set_smothering(on: bool) -> void:
	interaction.is_smothering = on


func set_wind_enabled(on: bool) -> void:
	_wind_enabled = on
	_apply_wind()


func set_wind_x(value: float) -> void:
	wind_vector.x = value
	_apply_wind()


func set_wind_z(value: float) -> void:
	wind_vector.z = value
	_apply_wind()


func set_debug_info(on: bool) -> void:
	debug_info = on
	solver.profiling = on
	water.profiling = on
	hud.overlay.visible = on


func set_advection_mode(index: int) -> void:
	solver.advection_mode = clampi(index, FireGpuSolver.ADVECTION_MACCORMACK,
		FireGpuSolver.ADVECTION_MACCORMACK_SCALARS)


func set_vorticity_mode(index: int) -> void:
	solver.vorticity_mode = clampi(index, FireGpuSolver.VORTICITY_FULL,
		FireGpuSolver.VORTICITY_OFF)


func set_simulation_hz(index: int) -> void:
	var rate_index := clampi(index, 0, FireQuality.SIMULATION_RATES.size() - 1)
	solver.set_simulation_hz(FireQuality.SIMULATION_RATES[rate_index])
	if solver.initialized:
		RenderingServer.call_on_render_thread(solver.capture_interpolation_state_render)


## How many simulation substeps one frame may spend catching the clock up. The
## solver runs its whole grid loop per substep, so this multiplies the frame's
## entire simulation cost — and the accumulator asks for more of them the slower
## the frame gets, which is a loop that only opens downwards. Capping it lets the
## simulation clock fall behind the wall clock instead, which is what the temporal
## interpolation is there to hide.
func set_max_catchup_steps(value: float) -> void:
	solver.max_catchup_steps = clampi(int(value), 1, 4)


func set_water_substeps(value: float) -> void:
	water_substeps = clampi(int(value), 4, 16)


func set_water_adaptive_substeps(on: bool) -> void:
	water_adaptive_substeps = on


func set_water_particle_cap(value: float) -> void:
	water_particle_cap = clampi(int(value), 1024, water.particle_count)
	interaction.set_particle_cap(water_particle_cap)


func set_render_scale(value: float) -> void:
	viewport_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


## Render scale and MSAA live on the root viewport, which outlives this demo:
## ViewportGuard puts back whatever this scene found.
func set_msaa(index: int) -> void:
	viewport_guard.set_msaa(
		FireQuality.MSAA_MODES[clampi(index, 0, FireQuality.MSAA_MODES.size() - 1)])


## Swap the tile pool budget.
##
## The display texture is freed on the render thread, so the binding is dropped
## and stepping suspended here, on the main thread, before the rebuild is queued.
## [member FireGpuSolver.initialized] comes back true at the end of the rebuild
## and [method _process] picks the new texture up on the next frame.
func set_pool_budget(index: int) -> void:
	var budget: int = FireGpuSolver.POOL_BUDGETS[index]
	if budget == solver.pool_budget:
		return

	solver.initialized = false
	presentation.unbind_textures()
	RenderingServer.call_on_render_thread(func() -> void:
		water.set_indirection_rid(RID())
		solver.set_pool_budget(budget)
		water.set_indirection_rid(solver.indirection_rid()))
	solver.reset_clock()
	_light_fire()


func _apply_wind() -> void:
	solver.wind = wind_vector if _wind_enabled else Vector3.ZERO


func _update_ui_stats(stats: Dictionary) -> void:
	var max_temp: float = stats["max_temperature"]
	var temp_norm := (max_temp - solver.ambient_temperature) \
		/ (solver.display_temperature - solver.ambient_temperature)
	menu_builder.update_stats(stats, temp_norm)
	if not gas_mode:
		menu_builder.refresh_wood(wood_pile)
