extends Node3D
## Fire Demo Controller — Fire-X combustion, volumetrically raymarched.

const FireWater = preload("res://scripts/fire/fire_water.gd")
const FireSceneDistance = preload("res://scripts/fire/fire_scene_distance.gd")
##
## The solver lives entirely in RenderingDevice textures (see FireGpuSolver);
## this node queues grid emitters, binds the display volume to the shader and
## drives the light and UI from the solver's reduced stats.
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

var debug_overlay: Label
var debug_info := true
var _debug_frame_ms := 0.0
var _debug_timing_frame := 0
var _debug_fire_timings := {}
var _debug_sph_timings := {}
var _debug_water_timings := {}
const DEBUG_TIMING_REFRESH_FRAMES := 15
var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar
var wood_bar: ProgressBar
var wood_label: Label
var wood_group: VBoxContainer
var gas_group: VBoxContainer
var flamethrower_group: VBoxContainer
var wood_section: Button
var gas_section: Button
var flamethrower_section: Button

var solver: FireGpuSolver
var water: FireWater
var volume_material: ShaderMaterial
var volume_texture: Texture3DRD
var previous_volume_texture: Texture3DRD
var indir_texture: Texture3DRD
var previous_indir_texture: Texture3DRD
var visual_activity_texture: Texture3DRD
var previous_visual_activity_texture: Texture3DRD
var texture_bound := false
var fluid_renderer: ScreenSpaceFluidRenderer

# --- Half-resolution volume pass (Phase 6 item 1) ---
## Visual layer the volume mesh moves to when the half-res pass is on, so the main
## camera stops drawing it and only the half-res camera does. Bits 2/4/8 belong to
## ScreenSpaceFluidRenderer's prepasses.
const LAYER_FIRE_VOLUME := 16
const VOLUME_UPSAMPLE_SHADER := "res://shaders/fire/fire_volume_upsample.gdshader"
var _volume_half_res := false
var _volume_vp: SubViewport
var _volume_cam: Camera3D
var _volume_composite: MeshInstance3D
var _volume_composite_mat: ShaderMaterial
var _scene_distance: CompositorEffect
var _scene_distance_tex: Texture2DRD
var _volume_vp_size := Vector2i.ZERO
var _external_depth_bound := false

# --- Fuel mode ---
var gas_mode := true
var _gas_fuel_index := 0
var gas_reinjection_enabled := true
const CAMPFIRE_SPAWN := Vector3(0.0, 1.2, 4.0)
var _mode_button: Button
var _log_button: Button
var _gas_reinjection_button: Button
var _ignite_button: Button
var _flamethrower_button: Button
var _flamethrower_firing := false
var _equipped := FireWeapons.Kind.NONE

# --- Quality presets ---
## Physical extent of the simulated box, held constant across presets so the
## flame keeps the same size on screen and only the resolution moves.
## The walls used to cut through the camp: the seat logs sit at r ~ 3.2 m and the
## boulders at r ~ 5-6 m, both outside the old 6.4 m box, and the smoke visibly
## piled up against a 9.6 m ceiling. Doubled on every axis so the plume leaves the
## domain through open air rather than through a wall.
## Cell size per preset. Tab. 3 allows 0.1-10.0 m, and 0.1 is the flame fidelity
## the domain was sized around; the coarser two exist because the domain grew 8x
## in volume at fixed cell size.
##
## Cost is cubic in the inverse: doubling the cell is 8x fewer cells for ~8x less
## GPU time, and the pressure loop alone is half of it.
enum PerformancePreset { REFERENCE, QUALITY, BALANCED, REALTIME_LITE, PERFORMANCE, AUTO }
const PERFORMANCE_PRESET_NAMES := [
	"Reference", "Quality", "Balanced", "Realtime Lite", "Performance", "Auto"]
const SIMULATION_RATES := [5, 10, 15, 30, 60, 120]
const AUTO_MIN_HOLD := 3.0
const AUTO_INITIAL_HOLD := 5.0
const AUTO_SLOW_FRAME_MS := 18.5
const AUTO_FAST_FRAME_MS := 15.0
const AUTO_MAX_LEVEL := 5
## Where Auto starts rather than at the Reference level 0. Level 0 is the paper's
## reference configuration, which measured 8 fps on the 760M in the heavy water
## scenario, so starting there means every session opens with several seconds of
## slideshow before the ladder walks down. Auto climbs back up on its own when
## frames are fast, so a machine that can afford level 0 loses nothing permanent.
const AUTO_START_LEVEL := 2
## Phase 6 item 4. Measured on the heavy scenario at Auto level 5: the main
## viewport's GPU time is 17.16 ms at 4x, 16.17 at 2x and 14.73 with MSAA off, so
## anti-aliasing is worth ~2.4 ms — about as much as the whole vorticity stage —
## and it is pure image quality, which is what a performance ladder is for.
const MSAA_MODES := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]
const MSAA_NAMES := ["Off", "2x", "4x"]

var _performance_preset := PerformancePreset.AUTO
var _msaa_entry_mode := -1
var _performance_controls := {}
var _preset_status_label: Label
var _auto_level := 0
var _auto_hold := 0.0
var _auto_frame_ms := 16.67
var _water_particle_cap := FireGpuSolver.WATER_PARTICLE_COUNT
var _water_particle_cap_applied := -1
var _water_substeps := 16
var _water_adaptive_substeps := false
var _temporal_interpolation := false

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

# --- Wood bed ---
## Starting heap, as (radius, angle, tilt) around the hearth: a tight core of
## three with an outer ring, so the outer logs have to be heated by the core
## before they contribute anything.
const STARTING_LOGS := [
	[0.10, 0.0, 0.10], [0.12, 2.1, -0.08], [0.11, 4.2, 0.12],
	[0.26, 1.0, 0.05], [0.26, 3.1, -0.05], [0.26, 5.2, 0.08],
]
var _log_cooldown := 0.0

# --- Water nozzle (Fire-X Fig. 8) ---
## The paper finds the spray aimed at the flame base is what stops the fire, so all
## three intensity presets aim there and vary how much water arrives per second.
## Each level sets the SPH emitter's frequency, velocity and spray cone; more water
## means a wider, faster, denser stream.
##
## Both the jet and the bucket leave the held weapon and converge on the crosshair.
var jet_enabled := false
# Frequency is particles/second, so it doubles as how dense the stream looks; all
# presets run well past Tab. 3's 100 Hz cap (game feel over the paper's nozzle) so
# the screen-space surface keeps enough neighbours in flight to fuse the stream
# into a continuous column rather than a dotted line. Gravity also nearly doubles
# the speed over the drop, stretching the spacing on the way down, so the rate has
# margin built in.
#
# Spray angle is 0: these are laminar jets, Fig. 8's other nozzle. A cone spreads
# the stream as it flies (5 deg over the ~6.7 m throw fans it from 0.12 m to ~0.4 m
# radius, an ~11x density drop), which pulls the droplets past the render radius
# and reads as golf balls flung in every direction. The paper prefers the spray for
# extinguishing, but the laminar stream is the one that looks like water.
#
const WATER_PRESETS := {
	1: {"freq": 420.0, "vel": 9.0, "spray": 0.0, "radius": 0.045},
	2: {"freq": 720.0, "vel": 12.0, "spray": 35.0, "radius": 0.05},
	3: {"freq": 1100.0, "vel": 15.0, "spray": 50.0, "radius": 0.055},
}
var _water_level := 0
var _water_buttons := {}
var _bucket_cooldown := 0.0
## A bucket is a lob, not a firehose: one throw every this many seconds.
const BUCKET_INTERVAL := 0.5

# --- Interaction state ---
var is_smothering := false

## The toggle gates the sliders rather than writing the wind itself, so turning
## it off stays off no matter where the sliders sit.
var _wind_enabled := false
var _wind_vector := Vector3(2.0, 0.0, 0.5)


func _apply_wind() -> void:
	solver.wind = _wind_vector if _wind_enabled else Vector3.ZERO


func _ready() -> void:
	solver = FireGpuSolver.new()
	solver.profiling = debug_info
	volume_material = fire_volume.material_override as ShaderMaterial
	if volume_material:
		_setup_volume_material()

	RenderingServer.call_on_render_thread(solver.init_render)

	# P3/P4: SPH water droplets and their coupling to the grid. The screen-space
	# surface only reconstructs where droplets pack tight, so the budget is large
	# enough to keep both a dense in-flight column and a connected floor puddle
	# alive at once — a smaller budget starves the stream into falling beads.
	water = FireWater.new()
	water.particle_count = FireGpuSolver.WATER_PARTICLE_COUNT
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

	_setup_fluid_renderer()
	_setup_half_res_volume()
	_build_wood_bed()
	_setup_ui()
	_set_fuel_mode(false)


func _process(delta: float) -> void:
	_debug_frame_ms = delta * 1000.0 if _debug_frame_ms == 0.0 else lerpf(
		_debug_frame_ms, delta * 1000.0, 0.1)
	_update_auto_quality(delta)
	if not solver.initialized:
		_update_debug_overlay()
		return
	if not texture_bound:
		volume_texture = Texture3DRD.new()
		volume_texture.texture_rd_rid = solver.get_display_tex_rid()
		previous_volume_texture = Texture3DRD.new()
		previous_volume_texture.texture_rd_rid = solver.get_previous_display_tex_rid()
		if volume_material:
			volume_material.set_shader_parameter("volume_tex", volume_texture)
			volume_material.set_shader_parameter("volume_tex_prev", previous_volume_texture)
			# The display field is an atlas of resident tiles, so the shader also needs
			# the map from virtual tile to atlas slot to read it.
			indir_texture = Texture3DRD.new()
			indir_texture.texture_rd_rid = solver.indirection_bytes_rid()
			volume_material.set_shader_parameter("indir_tex", indir_texture)
			previous_indir_texture = Texture3DRD.new()
			previous_indir_texture.texture_rd_rid = solver.previous_indirection_bytes_rid()
			volume_material.set_shader_parameter("indir_tex_prev", previous_indir_texture)
			visual_activity_texture = Texture3DRD.new()
			visual_activity_texture.texture_rd_rid = solver.get_texture_rid("visual_activity")
			volume_material.set_shader_parameter("visual_activity_tex", visual_activity_texture)
			previous_visual_activity_texture = Texture3DRD.new()
			previous_visual_activity_texture.texture_rd_rid = \
				solver.get_previous_visual_activity_tex_rid()
			volume_material.set_shader_parameter("visual_activity_tex_prev",
				previous_visual_activity_texture)
		fire_volume.visible = true
		texture_bound = true
	if volume_material:
		_set_volume_proxy(solver.display_clip_box())

	# Last frame's reduction, read up front: the wood bed is driven by the per-log
	# gas temperatures in it, and its emitters have to be uploaded before the
	# solver steps.
	var stats := solver.get_stats()
	var aim := _aim()
	if _flamethrower_firing and not gas_mode:
		var muzzle := weapons.muzzle_position()
		var direction := _weapon_direction(aim, muzzle)
		solver.set_torch(muzzle, direction, solver.torch_length)
		solver.set_torch_seed(muzzle, muzzle + direction * solver.torch_length,
			solver.torch_tip_radius + solver.cell_size * 8.0)
		weapons.set_firing(true)
	else:
		solver.clear_torch()
		weapons.set_firing(false)
	var step_count := solver.schedule_steps(delta)
	var run_fire := step_count > 0
	var sim_dt := float(step_count) * solver.timestep
	_set_volume_parameter("temporal_blend",
		solver.interpolation_alpha() if _temporal_interpolation else 1.0)
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

		if is_smothering:
			solver.push_event(FireGpuSolver.EVENT_SMOTHER, Vector3.ZERO, 2.0, 20.0 * sim_dt)

	_bucket_cooldown = maxf(_bucket_cooldown - delta, 0.0)
	_log_cooldown = maxf(_log_cooldown - delta, 0.0)

	# P3: water particle↔grid coupling. Algorithm 1 puts the scatter and the gather
	# both ahead of the grid loop (lines 13-14) so the solver reads the liquid field
	# built this frame, and the return after it (lines 23-24).
	if water.initialized:
		if _water_particle_cap_applied != _water_particle_cap:
			_water_particle_cap_applied = _water_particle_cap
		if jet_enabled:
			_aim_weapon(aim)
	var liquid_scal := solver.get_texture_rid("liquid_scal")
	var liquid_vel := solver.get_texture_rid("liquid_vel")
	var water_cap := _water_particle_cap
	var water_steps := _water_substeps
	var water_adaptive := _water_adaptive_substeps
	var emit_water := jet_enabled
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

	if water.initialized:
		fluid_renderer.update(water.sph_position_tex_rid(), water.particles_active)

	_update_half_res_volume()
	_update_light(stats)
	_update_ui_stats(stats)
	_update_debug_overlay()
	if spark_particles:
		spark_particles.emitting = stats["max_reaction"] > 0.1


func _exit_tree() -> void:
	if _msaa_entry_mode >= 0:
		get_viewport().msaa_3d = _msaa_entry_mode
	if _scene_distance_tex != null:
		_scene_distance_tex.texture_rd_rid = RID()
	if _scene_distance != null:
		RenderingServer.call_on_render_thread(_scene_distance.free_render)
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	if previous_volume_texture != null:
		previous_volume_texture.texture_rd_rid = RID()
	if indir_texture != null:
		indir_texture.texture_rd_rid = RID()
	if previous_indir_texture != null:
		previous_indir_texture.texture_rd_rid = RID()
	if visual_activity_texture != null:
		visual_activity_texture.texture_rd_rid = RID()
	if previous_visual_activity_texture != null:
		previous_visual_activity_texture.texture_rd_rid = RID()
	# Water first: its uniform sets bind the solver's liquid textures, and freeing
	# those first makes Godot drop the dependent sets on its own — FireWater then
	# frees RIDs that are already gone ("Attempted to free invalid ID").
	RenderingServer.call_on_render_thread(water.free_render)
	RenderingServer.call_on_render_thread(solver.free_render)


# =========================================================================
#  AIMING AND INPUT
# =========================================================================

## Where the player is looking: the camera, its forward axis, and the first solid
## along it (capped, so aiming at the sky still yields a usable point).
func _aim() -> Dictionary:
	var cam := player.get_camera()
	var origin := cam.global_position
	var direction := -cam.global_transform.basis.z
	var point := origin + direction * 4.0
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 12.0)
	query.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.has("position"):
		point = hit["position"]
	return {"origin": origin, "direction": direction, "point": point}


## Mouse buttons only reach here while the cursor is captured: FpsWalker consumes
## the click that recaptures it, so nothing fires on the click that hands focus
## back to the viewport.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_G:
				_drop_log()


# =========================================================================
#  FUEL MODE
# =========================================================================

## Swap fuel source in place. The campfire scene and solver stay loaded.
func _set_fuel_mode(use_gas: bool) -> void:
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
	jet_enabled = false
	_water_level = 0
	_flamethrower_firing = false
	solver.clear_torch()
	_equip_weapon(FireWeapons.Kind.NONE)
	weapons.set_firing(false)
	_smooth_light_energy = 0.0
	_smooth_light_range = 8.0
	_light_fire()
	_refresh_fuel_mode_ui()


func _refresh_fuel_mode_ui() -> void:
	if _mode_button == null:
		return
	menu.title = "🔥 Campfire — Gas (Fire-X)" if gas_mode else "🔥 Campfire — Wood (Fire-X)"
	_mode_button.text = "⛽" if gas_mode else "🪵"
	_mode_button.set_pressed_no_signal(gas_mode)
	_log_button.visible = not gas_mode
	_gas_reinjection_button.visible = gas_mode
	_gas_reinjection_button.set_pressed_no_signal(gas_reinjection_enabled)
	_ignite_button.visible = gas_mode
	_flamethrower_button.visible = not gas_mode
	_flamethrower_button.set_pressed_no_signal(false)
	for level in _water_buttons:
		_water_buttons[level].set_pressed_no_signal(false)
		_water_buttons[level].visible = true
	wood_group.visible = not gas_mode
	wood_section.visible = not gas_mode
	flamethrower_group.visible = not gas_mode
	flamethrower_section.visible = not gas_mode
	gas_group.visible = gas_mode
	gas_section.visible = gas_mode
	_refresh_wood_label()


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


func _drop_log() -> void:
	if gas_mode or _log_cooldown > 0.0 or wood_pile.is_full():
		return
	wood_pile.add_log_on_pile(randf() * TAU, randf_range(-0.12, 0.12))
	_log_cooldown = 0.4
	_refresh_wood_label()


# =========================================================================
#  SCENE SETUP
# =========================================================================

## Point the raymarcher at the grid the solver runs on.
func _setup_volume_material() -> void:
	var box := Vector3(solver.sim_dims()) * solver.cell_size
	volume_material.set_shader_parameter("cell_size", solver.cell_size)
	volume_material.set_shader_parameter("atlas_cells", Vector3(FireTilePool.ATLAS_CELLS))
	volume_material.set_shader_parameter("atlas_tiles", FireTilePool.ATLAS_TILES)
	volume_material.set_shader_parameter("virtual_tiles", FireTilePool.VTILES)
	volume_material.set_shader_parameter("virtual_origin",
		Vector3(-box.x * 0.5, 0.0, -box.z * 0.5))
	_set_volume_proxy(solver.display_clip_box())
	# The blue reaction core fades over the height of a burner-sized domain; over
	# the virtual one it would never fade at all.
	volume_material.set_shader_parameter("blue_height", FireGpuSolver.DOMAIN_SIZE.y)
	# The volume stores temperature normalised against these, so the shader
	# needs them to turn the red channel back into kelvins.
	volume_material.set_shader_parameter("ambient_temperature", solver.ambient_temperature)
	volume_material.set_shader_parameter("display_temperature", solver.display_temperature)
	# Nothing to march until the solver's textures exist: an unbound sampler falls
	# back to Godot's default texture, which for the indirection volume is not even
	# the right format to read.
	fire_volume.visible = false


func _set_volume_proxy(proxy: AABB) -> void:
	var extent := proxy.size
	(fire_volume.mesh as BoxMesh).size = extent
	fire_volume.position = proxy.position + extent * 0.5
	volume_material.set_shader_parameter("box_size", extent)
	volume_material.set_shader_parameter("volume_origin", proxy.position)
	volume_material.set_shader_parameter("volume_extent", extent)


## Screen-space fluid surface over the SPH position texture, reusing the fluid
## demo's render chain (ScreenSpaceFluidRenderer) instead of per-particle sphere
## impostors, so the droplets read as one connected body of water and a clean
## puddle rather than colored balls. The renderer binds the position texture
## lazily once the queued init_render has produced the RID (see its update()).
func _setup_fluid_renderer() -> void:
	fluid_renderer = ScreenSpaceFluidRenderer.new()
	fluid_renderer.camera = player.get_camera()
	fluid_renderer.particle_count = water.particle_count
	fluid_renderer.tex_width = water.sph_tex_width()
	fluid_renderer.radius = 0.05
	fluid_renderer.mode = 0.0
	fluid_renderer.render_scale = 1.0
	# Matches the fire grid box so the surface MultiMesh is not frustum-culled.
	fluid_renderer.domain_aabb = AABB(Vector3(-0.5, 0.0, -0.5) * FireGpuSolver.DOMAIN_SIZE,
		FireGpuSolver.DOMAIN_SIZE)
	# Foam deferred: land the clean surface + puddle first.
	fluid_renderer.build_foam = false
	add_child(fluid_renderer)
	fluid_renderer.start()

	var cm := fluid_renderer.composite_material()
	cm.render_priority = 0
	cm.set_shader_parameter("sky_zenith", Color(0.08, 0.28, 0.5))
	cm.set_shader_parameter("sky_horizon", Color(0.16, 0.5, 0.8))
	cm.set_shader_parameter("sun_intensity", 0.0)
	cm.set_shader_parameter("tint_color", Color(0.06, 0.38, 0.68))
	cm.set_shader_parameter("absorption_scale", 0.25)


## Phase 6 item 1: march the volume at half the linear resolution — a quarter of
## the rays — and put it back on screen with a depth-aware upsample.
##
## The volume mesh stays exactly where it is in the world; what moves is which
## camera is allowed to see it. On its own visual layer the main camera skips it
## and a half-res SubViewport camera draws it instead, so nothing about the march
## changes except how many fragments run it. The one thing a SubViewport cannot
## have is the main render's depth buffer, which is what the ray stops against —
## FireSceneDistance publishes it as a texture (see that class for the one-frame
## lag this implies).
func _setup_half_res_volume() -> void:
	_volume_vp = SubViewport.new()
	_volume_vp.own_world_3d = false
	_volume_vp.transparent_bg = true
	_volume_vp.use_hdr_2d = true
	_volume_vp.msaa_3d = Viewport.MSAA_DISABLED
	_volume_vp.positional_shadow_atlas_size = 0
	_volume_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_volume_vp.size = Vector2i(2, 2)
	add_child(_volume_vp)
	_volume_cam = Camera3D.new()
	_volume_cam.cull_mask = LAYER_FIRE_VOLUME
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	_volume_cam.environment = env
	_volume_vp.add_child(_volume_cam)
	_volume_cam.current = true

	_volume_composite_mat = ShaderMaterial.new()
	_volume_composite_mat.shader = load(VOLUME_UPSAMPLE_SHADER)
	_volume_composite_mat.set_shader_parameter("volume_tex", _volume_vp.get_texture())
	# Above the water composite, matching the volume mesh's own render priority.
	_volume_composite_mat.render_priority = 1
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = _volume_composite_mat
	_volume_composite = MeshInstance3D.new()
	_volume_composite.mesh = quad
	_volume_composite.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	_volume_composite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_volume_composite.visible = false
	add_child(_volume_composite)

	_scene_distance = FireSceneDistance.new()
	_scene_distance.enabled = false
	var compositor := Compositor.new()
	compositor.compositor_effects = [_scene_distance]
	player.get_camera().compositor = compositor


func _set_volume_half_res(on: bool) -> void:
	if _volume_vp == null:
		return
	_volume_half_res = on
	var cam := player.get_camera()
	fire_volume.layers = LAYER_FIRE_VOLUME if on else 1
	cam.cull_mask = (cam.cull_mask & ~LAYER_FIRE_VOLUME) if on \
		else (cam.cull_mask | LAYER_FIRE_VOLUME)
	_volume_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on \
		else SubViewport.UPDATE_DISABLED
	_scene_distance.enabled = on
	if not on:
		_external_depth_bound = false
		_set_volume_parameter("external_scene_depth", false)
		_volume_composite.visible = false


## Track the window, the global render scale and the distance texture's RID, all
## three of which can change under a running demo.
func _update_half_res_volume() -> void:
	if not _volume_half_res:
		return
	_volume_cam.global_transform = player.get_camera().global_transform
	_volume_cam.fov = player.get_camera().fov
	_volume_cam.near = player.get_camera().near
	_volume_cam.far = player.get_camera().far
	# Half of what the main viewport actually renders at, not half of the window:
	# the global render scale already shrinks the main render, and the composite's
	# upsample assumes the two agree.
	var vp := get_viewport()
	var internal := Vector2(vp.size) * vp.scaling_3d_scale
	var half := Vector2i(maxi(int(internal.x) / 2, 1), maxi(int(internal.y) / 2, 1))
	if half != _volume_vp_size:
		_volume_vp_size = half
		_volume_vp.size = half
		_volume_composite_mat.set_shader_parameter("low_res_size", Vector2(half))
	# The effect allocates its texture on the render thread, so the first frames
	# after the toggle have no distance texture at all. Binding a Texture2DRD that
	# holds no RD texture yet builds a material uniform set the pipeline rejects
	# ("Uniforms supplied for set (3) are not the same format"), and marching
	# against the sampler's white fallback would truncate every ray at 1 m — so
	# both the parameter and the external-depth switch wait for a live RID.
	var dist: RID = _scene_distance.output_rid
	if not dist.is_valid():
		return
	if _scene_distance_tex == null:
		_scene_distance_tex = Texture2DRD.new()
	if _scene_distance_tex.texture_rd_rid != dist:
		# Assigning straight over a live RID goes through texture_replace, which frees
		# the RD texture underneath it — one the effect owns and recycles. Clearing
		# first only drops the wrapper, which is all that should happen here.
		_scene_distance_tex.texture_rd_rid = RID()
		_scene_distance_tex.texture_rd_rid = dist
		_set_volume_parameter("scene_distance_tex", _scene_distance_tex)
		_volume_composite_mat.set_shader_parameter("scene_distance_tex",
			_scene_distance_tex)
		_external_depth_bound = false
	if not _external_depth_bound:
		_external_depth_bound = true
		_set_volume_parameter("external_scene_depth", true)
	_volume_composite.visible = fire_volume.visible


## The three water buttons are a radio group: turning one on selects that intensity
## and clears the others; turning the active one off stops the jet.
func _set_water_level(level: int, on: bool) -> void:
	if not on:
		if _water_level == level:
			jet_enabled = false
			_water_level = 0
			if _equipped == FireWeapons.Kind.WATER_GUN:
				_equip_weapon(FireWeapons.Kind.NONE)
		return
	_stop_flamethrower()
	_equip_weapon(FireWeapons.Kind.WATER_GUN)
	_water_level = level
	jet_enabled = true
	var p: Dictionary = WATER_PRESETS[level]
	water.jet_frequency = p.freq
	water.jet_velocity = p.vel
	water.jet_spray_angle = p.spray
	fluid_renderer.set_radius(p.radius)
	for lv in _water_buttons:
		if lv != level:
			_water_buttons[lv].set_pressed_no_signal(false)


func _weapon_direction(aim: Dictionary, muzzle: Vector3) -> Vector3:
	var direction: Vector3 = aim["point"] - muzzle
	return direction.normalized() if direction.length() > 1.2 else aim["direction"]


func _aim_weapon(aim: Dictionary) -> void:
	var muzzle := weapons.muzzle_position()
	water.jet_position = muzzle
	water.jet_direction = _weapon_direction(aim, muzzle)


func _equip_weapon(kind: int) -> void:
	_equipped = kind
	weapons.equip(kind)


func _stop_flamethrower() -> void:
	_flamethrower_firing = false
	solver.clear_torch()
	weapons.set_firing(false)
	if _flamethrower_button != null:
		_flamethrower_button.set_pressed_no_signal(false)


func _set_flamethrower(on: bool) -> void:
	if gas_mode:
		_flamethrower_firing = false
		return
	_flamethrower_firing = on
	if on:
		jet_enabled = false
		_water_level = 0
		for level in _water_buttons:
			_water_buttons[level].set_pressed_no_signal(false)
		_equip_weapon(FireWeapons.Kind.FLAMETHROWER)
		weapons.set_firing(true)
	else:
		solver.clear_torch()
		weapons.set_firing(false)
		if _equipped == FireWeapons.Kind.FLAMETHROWER:
			_equip_weapon(FireWeapons.Kind.NONE)


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


func _set_gas_reinjection(on: bool) -> void:
	gas_reinjection_enabled = on


func _ignite_gas() -> void:
	if not gas_mode:
		return
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)


## Queued rather than called, because init_render is itself queued: calling
## directly would run against a FireWater that has not allocated its buffers yet
## and spawn nothing.
func _pour_water() -> void:
	if _bucket_cooldown > 0.0 or not water.initialized:
		return
	_bucket_cooldown = BUCKET_INTERVAL
	# A bucket lobbed at the fire, not a packed ball: the old version put the whole
	# budget in a 0.4 m sphere, whose SPH pressure detonated it into an explosion.
	# It leaves the player's hands spread over a wide loose volume so the solver
	# does not blow it apart.
	_stop_flamethrower()
	_equip_weapon(FireWeapons.Kind.WATER_GUN)
	var aim := _aim()
	var muzzle := weapons.muzzle_position()
	var direction := _weapon_direction(aim, muzzle)
	var origin: Vector3 = muzzle + direction * 1.2
	var throw: Vector3 = direction * 8.0
	RenderingServer.call_on_render_thread(water.spawn_droplets.bind(
		mini(_water_particle_cap, 2000), origin, 0.5, throw))


## Quality knobs per preset.
##
## [code]catchup[/code] is the substep budget a frame may spend catching the
## simulation clock up. It is the largest single lever measured on the 760M — the
## solver runs the whole grid loop once per substep, so a frame that takes four of
## them costs four times a frame that takes one, and a slow frame asks for MORE
## substeps than a fast one. Left at four for Reference, which is the fidelity
## control; every playable preset caps it and lets the temporal interpolation
## cover the difference.
##
## [code]pressure[/code] counts dispatches of the projection, and the playable
## presets are at half what they used to be because the solver behind it changed
## (Phase 2: block Gauss-Seidel plus a tile-level coarse solve). Measured at 2048
## resident tiles, the new solver at 32 passes leaves a residual of 0.015 where
## the old one left 0.087 at 64, so every one of these halvings buys accuracy as
## well as milliseconds. Reference keeps the paper's 64 (Tab. 3 range 64-128): it
## is the control, and there it now costs 23 % more for an 18x lower residual.
##
## [code]advection[/code] has a middle rung since Phase 3: mode 2 corrects the
## scalars with MacCormack and leaves the velocity on plain semi-Lagrangian.
## Measured at 2048 tiles it is 5.1 ms against 8.8 for the full correction and 0
## for none, and it holds the plume at 2118 K / 9.07 total reaction where dropping
## the correction entirely gives 1984 K / 7.05. That is roughly proportional — it
## is a rung on the ladder, not a free lunch — so it goes where the ladder used to
## step straight from full MacCormack to none.
func _preset_values(index: int) -> Dictionary:
	match index:
		PerformancePreset.QUALITY:
			return {pressure = 32, advection = 0, vorticity_mode = 0,
				vorticity_frequency = 1, simulation_hz = 30, temporal = false,
				catchup = 3, water_substeps = 16, water_adaptive = true,
				water_cap = 16384, march_step = 1.0, march_budget = 280,
				march_distance = 72.0, water_scale = 0.8, render_scale = 1.0,
				msaa = 2, volume_half = false}
		PerformancePreset.BALANCED:
			return {pressure = 24, advection = 0, vorticity_mode = 1,
				vorticity_frequency = 2, simulation_hz = 30, temporal = false,
				catchup = 2, water_substeps = 14, water_adaptive = true,
				water_cap = 12288, march_step = 1.5, march_budget = 192,
				march_distance = 56.0, water_scale = 0.55, render_scale = 0.8,
				msaa = 1, volume_half = true}
		PerformancePreset.REALTIME_LITE:
			return {pressure = 16, advection = 2, vorticity_mode = 1,
				vorticity_frequency = 2, simulation_hz = 15, temporal = true,
				catchup = 1, water_substeps = 12, water_adaptive = true,
				water_cap = 8192, march_step = 2.0, march_budget = 128,
				march_distance = 40.0, water_scale = 0.4, render_scale = 0.65,
				msaa = 1, volume_half = true}
		PerformancePreset.PERFORMANCE:
			return {pressure = 16, advection = 1, vorticity_mode = 2,
				vorticity_frequency = 4, simulation_hz = 30, temporal = false,
				catchup = 1, water_substeps = 12, water_adaptive = true,
				water_cap = 8192, march_step = 2.0, march_budget = 128,
				march_distance = 40.0, water_scale = 0.4, render_scale = 0.65,
				msaa = 0, volume_half = true}
		_:
			return {pressure = 64, advection = 0, vorticity_mode = 0,
				vorticity_frequency = 1, simulation_hz = 30, temporal = false,
				catchup = 4, water_substeps = 16, water_adaptive = false,
				water_cap = 16384, march_step = 0.75, march_budget = 320,
				march_distance = 80.0, water_scale = 1.0, render_scale = 1.0,
				msaa = 2, volume_half = false}


## The Auto ladder. Levels 1-3 give up rendering only, 4-5 then reduce the
## simulation — except for the pressure count, which every level overrides off
## Reference's 64: Reference keeps the paper's iteration count because it is the
## fidelity control, but there is no reason for an automatic ladder to pay for it
## when 32 passes of the Phase 2 solver already leave a lower residual than 64 of
## the old one.
##
## Water render scale falls first and fastest: the screen-space droplet pipeline
## (five sub-viewports) measured ~54 ms of a 121 ms frame with the hose open, more
## than the whole solver, and it is the one cost that scales with the square of a
## single number.
func _auto_values(level: int) -> Dictionary:
	var values := _preset_values(PerformancePreset.REFERENCE)
	match level:
		1:
			values.merge({pressure = 32, march_step = 1.0, march_budget = 280,
				march_distance = 72.0, water_scale = 0.6}, true)
		2:
			values.merge({pressure = 32, march_step = 1.25, march_budget = 240,
				march_distance = 64.0, water_scale = 0.5, render_scale = 0.9,
				volume_half = true}, true)
		3:
			values.merge({pressure = 32, march_step = 1.5, march_budget = 192,
				march_distance = 56.0, water_scale = 0.45, render_scale = 0.8,
				msaa = 1, volume_half = true}, true)
		4:
			values.merge({pressure = 24, advection = 2, vorticity_mode = 1,
				vorticity_frequency = 2,
				catchup = 2, water_substeps = 12, water_adaptive = true,
				water_cap = 12288, march_step = 1.75,
				march_budget = 160, march_distance = 48.0, water_scale = 0.4,
				render_scale = 0.75, msaa = 1, volume_half = true}, true)
		5:
			values = _preset_values(PerformancePreset.PERFORMANCE)
	return values


func _set_performance_preset(index: int) -> void:
	_performance_preset = clampi(index, 0, PERFORMANCE_PRESET_NAMES.size() - 1)
	if _performance_preset == PerformancePreset.AUTO:
		_auto_level = AUTO_START_LEVEL
		_auto_hold = AUTO_INITIAL_HOLD
		_auto_frame_ms = maxf(_debug_frame_ms, 16.67)
		_apply_performance_values(_auto_values(_auto_level))
		_update_preset_status()
		return
	_apply_performance_values(_preset_values(_performance_preset))
	_update_preset_status()


func _apply_performance_values(values: Dictionary) -> void:
	_set_performance_control("pressure", values.pressure)
	_set_performance_control("advection", values.advection)
	_set_performance_control("vorticity_mode", values.vorticity_mode)
	_set_performance_control("vorticity_frequency", values.vorticity_frequency)
	_set_performance_control("simulation_hz", SIMULATION_RATES.find(values.simulation_hz))
	_set_performance_control("temporal", values.temporal)
	_set_performance_control("catchup", values.catchup)
	_set_performance_control("water_substeps", values.water_substeps)
	_set_performance_control("water_adaptive", values.water_adaptive)
	_set_performance_control("water_cap", values.water_cap)
	_set_performance_control("march_step", values.march_step)
	_set_performance_control("march_budget", values.march_budget)
	_set_performance_control("march_distance", values.march_distance)
	_set_performance_control("water_scale", values.water_scale)
	_set_performance_control("render_scale", values.render_scale)
	_set_performance_control("msaa", values.msaa)
	_set_performance_control("volume_half", values.volume_half)


func _set_performance_control(key: String, value: Variant) -> void:
	if not _performance_controls.has(key):
		return
	var entry: Dictionary = _performance_controls[key]
	var node: Control = entry.node
	var callback: Callable = entry.callback
	if node is HSlider:
		var slider := node as HSlider
		if is_equal_approx(slider.value, float(value)):
			callback.call(float(value))
		else:
			slider.value = float(value)
	elif node is OptionButton:
		var option := node as OptionButton
		option.select(int(value))
		callback.call(int(value))
	elif node is CheckButton:
		var toggle := node as CheckButton
		toggle.set_pressed_no_signal(bool(value))
		callback.call(bool(value))


func _register_performance_control(key: String, node: Control, callback: Callable) -> void:
	_performance_controls[key] = {node = node, callback = callback}


func _update_auto_quality(delta: float) -> void:
	if _performance_preset != PerformancePreset.AUTO:
		return
	_auto_frame_ms = lerpf(_auto_frame_ms, minf(delta * 1000.0, 250.0), 0.05)
	_auto_hold -= delta
	if _auto_hold <= 0.0:
		var next_level := _auto_level
		if _auto_frame_ms > AUTO_SLOW_FRAME_MS and _auto_level < AUTO_MAX_LEVEL:
			# Proportional, because one level per hold is far too slow to be useful
			# from where this actually starts: the measured worst case is 121 ms, and
			# stepping one level every three seconds spends seventeen seconds walking
			# down a ladder the first adjustment could have descended. Each level is
			# worth roughly a factor of two, so the overshoot in octaves is the number
			# of levels to drop.
			var octaves := log(_auto_frame_ms / AUTO_SLOW_FRAME_MS) / log(2.0)
			next_level = mini(_auto_level + maxi(int(ceil(octaves)), 1), AUTO_MAX_LEVEL)
		elif _auto_frame_ms < AUTO_FAST_FRAME_MS and _auto_level > 0:
			# One at a time on the way back up: fast down, slow up, so the ladder
			# settles instead of oscillating around the threshold.
			next_level -= 1
		if next_level != _auto_level:
			_auto_level = next_level
			_apply_performance_values(_auto_values(_auto_level))
			_auto_hold = AUTO_MIN_HOLD
	_update_preset_status()


func _update_preset_status() -> void:
	if _preset_status_label == null:
		return
	if _performance_preset == PerformancePreset.AUTO:
		var scope := "simulation reduced" if _auto_level >= 4 else "rendering only"
		_preset_status_label.text = "Auto level %d/%d · %s · %.1f ms" % [
			_auto_level, AUTO_MAX_LEVEL, scope, _auto_frame_ms]
	else:
		_preset_status_label.text = "%s · explicit, reversible settings" % \
			PERFORMANCE_PRESET_NAMES[_performance_preset]


func _set_advection_mode(index: int) -> void:
	solver.advection_mode = clampi(index, FireGpuSolver.ADVECTION_MACCORMACK,
		FireGpuSolver.ADVECTION_MACCORMACK_SCALARS)


func _set_simulation_hz(index: int) -> void:
	var rate_index := clampi(index, 0, SIMULATION_RATES.size() - 1)
	solver.set_simulation_hz(SIMULATION_RATES[rate_index])
	if solver.initialized:
		RenderingServer.call_on_render_thread(solver.capture_interpolation_state_render)


## How many simulation substeps one frame may spend catching the clock up. The
## solver runs its whole grid loop per substep, so this multiplies the frame's
## entire simulation cost — and the accumulator asks for more of them the slower
## the frame gets, which is a loop that only opens downwards. Capping it lets the
## simulation clock fall behind the wall clock instead, which is what the temporal
## interpolation is there to hide.
func _set_max_catchup_steps(value: float) -> void:
	solver.max_catchup_steps = clampi(int(value), 1, 4)


func _set_temporal_interpolation(on: bool) -> void:
	_temporal_interpolation = on
	_set_volume_parameter("temporal_blend", solver.interpolation_alpha() if on else 1.0)
	if on and solver.initialized:
		RenderingServer.call_on_render_thread(solver.capture_interpolation_state_render)


func _set_vorticity_mode(index: int) -> void:
	solver.vorticity_mode = clampi(index, FireGpuSolver.VORTICITY_FULL,
		FireGpuSolver.VORTICITY_OFF)


func _set_water_particle_cap(value: float) -> void:
	_water_particle_cap = clampi(int(value), 1024, water.particle_count)


func _set_water_substeps(value: float) -> void:
	_water_substeps = clampi(int(value), 4, 16)


func _set_water_adaptive_substeps(value: bool) -> void:
	_water_adaptive_substeps = value


func _set_volume_parameter(name: String, value: Variant) -> void:
	if volume_material != null:
		volume_material.set_shader_parameter(name, value)


func _set_water_render_scale(value: float) -> void:
	if fluid_renderer != null:
		fluid_renderer.set_render_scale(value)


## Swap the tile pool budget.
##
## The display texture is freed on the render thread, so the binding is dropped
## and stepping suspended here, on the main thread, before the rebuild is queued.
## [member FireGpuSolver.initialized] comes back true at the end of the rebuild
## and [method _process] picks the new texture up on the next frame.
func _set_quality(index: int) -> void:
	var budget: int = FireGpuSolver.POOL_BUDGETS[index]
	if budget == solver.pool_budget:
		return

	solver.initialized = false
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	if previous_volume_texture != null:
		previous_volume_texture.texture_rd_rid = RID()
	if indir_texture != null:
		indir_texture.texture_rd_rid = RID()
	if previous_indir_texture != null:
		previous_indir_texture.texture_rd_rid = RID()
	if visual_activity_texture != null:
		visual_activity_texture.texture_rd_rid = RID()
	if previous_visual_activity_texture != null:
		previous_visual_activity_texture.texture_rd_rid = RID()
	fire_volume.visible = false
	texture_bound = false
	RenderingServer.call_on_render_thread(func() -> void:
		water.set_indirection_rid(RID())
		solver.set_pool_budget(budget)
		water.set_indirection_rid(solver.indirection_rid()))
	solver.reset_clock()
	_light_fire()


func _reset_simulation() -> void:
	solver.reset_clock()
	RenderingServer.call_on_render_thread(solver.clear_fields)
	water.reset_droplets()
	RenderingServer.call_on_render_thread(water.clear_droplets)
	jet_enabled = false
	_water_level = 0
	_flamethrower_firing = false
	solver.clear_torch()
	_equip_weapon(FireWeapons.Kind.NONE)
	weapons.set_firing(false)
	if _flamethrower_button != null:
		_flamethrower_button.set_pressed_no_signal(false)
	_bucket_cooldown = 0.0
	for level in _water_buttons:
		_water_buttons[level].set_pressed_no_signal(false)
	_smooth_light_energy = 0.0
	_smooth_light_range = 8.0
	if not gas_mode:
		wood_pile.clear()
		_build_wood_bed()
	_light_fire()
	_refresh_wood_label()


# =========================================================================
#  LIGHT
# =========================================================================

var _smooth_light_energy := 0.0
var _smooth_light_range := 8.0

func _update_light(stats: Dictionary) -> void:
	if not fire_light:
		return

	var dt := get_process_delta_time()
	var light_blend := clampf(3.0 * dt, 0.0, 1.0)

	var temp_norm := clampf(
		(stats["max_temperature"] - solver.ambient_temperature)
			/ (solver.display_temperature - solver.ambient_temperature),
		0.0, 1.0
	)

	_smooth_light_energy = lerpf(_smooth_light_energy, temp_norm * 8.0, light_blend)
	_smooth_light_range = lerpf(_smooth_light_range, 8.0 + temp_norm * 14.0, light_blend)

	fire_light.light_energy = _smooth_light_energy
	fire_light.omni_range = _smooth_light_range

	# Planck-like mapping: dull red embers through to near-white at peak.
	var light_color := Color(1.0, 0.55, 0.15)
	if temp_norm > 0.7:
		light_color = light_color.lerp(Color(1.0, 0.9, 0.7), (temp_norm - 0.7) / 0.3)
	elif temp_norm < 0.3:
		light_color = light_color.lerp(Color(0.8, 0.3, 0.1), 1.0 - temp_norm / 0.3)
	fire_light.light_color = light_color

	var flicker := 1.0 - 0.02 * sin(Time.get_ticks_msec() * 0.01) * cos(Time.get_ticks_msec() * 0.017)
	fire_light.light_energy *= flicker


# =========================================================================
#  UI
# =========================================================================

func _update_ui_stats(stats: Dictionary) -> void:
	var max_temp: float = stats["max_temperature"]
	var temp_norm := (max_temp - solver.ambient_temperature) \
		/ (solver.display_temperature - solver.ambient_temperature)

	fuel_bar.value = stats["avg_fuel"] * 100.0
	oxygen_bar.value = stats["avg_oxygen"] * 100.0
	temp_bar.value = clampf(temp_norm * 100.0, 0.0, 100.0)
	if not gas_mode:
		wood_bar.value = wood_pile.total_fuel() \
			/ maxf(wood_pile.initial_fuel(), 1e-4) * 100.0
		_refresh_wood_label()


func _update_debug_overlay() -> void:
	if debug_overlay == null or solver == null:
		return
	_debug_timing_frame += 1
	var stats := solver.get_stats()
	if _debug_timing_frame % DEBUG_TIMING_REFRESH_FRAMES == 0:
		var latest_timings := solver.get_timings()
		if not latest_timings.is_empty():
			_debug_fire_timings = latest_timings
	var timings: Dictionary = _debug_fire_timings
	var proxy := solver.display_clip_box()
	var clock := solver.get_clock_stats()
	var pool := solver.get_debug_pool_stats()
	var lines := [
		"FIRE DEBUG",
		"quality %s" % (_preset_status_label.text if _preset_status_label != null else "--"),
		"frame %.2f ms | FPS %.1f | steps %d" % [
			_debug_frame_ms, Engine.get_frames_per_second(), solver.last_substeps],
		"clock %d Hz | sim %.2f s | wall %.2f s | ratio %.3f" % [
			int(clock["simulation_hz"]), float(clock["simulation_time"]),
			float(clock["wall_time"]), float(clock["ratio"])],
		"temporal %s | blend %.2f" % [
			"linear" if _temporal_interpolation else "off",
			float(clock["interpolation_alpha"]) if _temporal_interpolation else 1.0],
		"backlog %.1f ms | dropped %.1f ms" % [
			float(clock["accumulator"]) * 1000.0, float(clock["dropped_time"]) * 1000.0],
		"GPU %s | stages %s" % [
			"%.2f ms" % timings["total"] if timings.has("total") else "--",
			_format_timings(timings) if not timings.is_empty() else "--"],
	]
	# Cores are the tiles that cleared the keep threshold on their own; the rest
	# are only resident because they fell in some core's dilation band. The split
	# is what says whether the pool is holding fire or margin.
	lines.append("pool %d/%d resident (%d core / %d band) | %d free | %d new | %d exhausted" % [
		int(pool.get("resident", 0)), int(pool.get("budget", solver.pool_budget)),
		int(pool.get("cores", 0)),
		int(pool.get("resident", 0)) - int(pool.get("cores", 0)),
		int(pool.get("free", 0)), int(pool.get("allocated_this_frame", 0)),
		int(pool.get("exhausted", 0))])
	lines.append("proxy (%.1f, %.1f, %.1f) size (%.1f, %.1f, %.1f)" % [
		proxy.position.x, proxy.position.y, proxy.position.z,
		proxy.size.x, proxy.size.y, proxy.size.z])
	lines.append("T %d K | reaction %.3f | div %.4f | ΣY %.4f" % [
		int(stats["max_temperature"]), stats["total_reaction"],
		stats["max_divergence"], stats["mass_fraction_sum"]])
	if water != null:
		if _debug_timing_frame % DEBUG_TIMING_REFRESH_FRAMES == 0:
			var latest_water_timings := water.get_coupling_timings()
			if not latest_water_timings.is_empty():
				_debug_water_timings = latest_water_timings
			var latest_sph_timings := water.sph.get_timings() if water.sph != null else {}
			if not latest_sph_timings.is_empty():
				_debug_sph_timings = latest_sph_timings
		var has_water_timings := water.particles_active > 0 and (
			_debug_sph_timings.has("total") or not _debug_water_timings.is_empty())
		var water_total := float(_debug_sph_timings.get("total", 0.0))
		for key in _debug_water_timings:
			water_total += float(_debug_water_timings[key])
		lines.append("water %d active | total %s ms | grid %s ms | scatter %s | gather %s" % [
			water.particles_active,
			"%.2f" % water_total if has_water_timings else "--",
			"%.2f" % _debug_sph_timings["grid"] if has_water_timings and _debug_sph_timings.has("grid") else "--",
			"%.2f ms" % _debug_water_timings["scatter"] if has_water_timings and _debug_water_timings.has("scatter") else "--",
			"%.2f ms" % _debug_water_timings["gather"] if has_water_timings and _debug_water_timings.has("gather") else "--"])
	debug_overlay.text = "\n".join(lines)


func _refresh_wood_label() -> void:
	if wood_label == null:
		return
	wood_label.text = "%d logs, %d burning, %.2f kg volatiles left" % [
		wood_pile.log_count(), wood_pile.burning_count(), wood_pile.total_fuel()]


## The five costliest stages, so the pressure loop's share of the frame is
## visible before the grid gets any bigger.
func _format_timings(timings: Dictionary) -> String:
	if timings.is_empty():
		return ""
	var rows := []
	for key in timings:
		if key != "total":
			rows.append([key, timings[key]])
	rows.sort_custom(func(a, b): return a[1] > b[1])

	var parts := []
	for i in mini(5, rows.size()):
		parts.append("%s %.1f" % [rows[i][0], rows[i][1]])
	return " · ".join(parts) + " ms"


func _setup_ui() -> void:
	debug_overlay = Label.new()
	debug_overlay.position = Vector2(16.0, 16.0)
	debug_overlay.custom_minimum_size = Vector2(620.0, 0.0)
	debug_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_overlay.add_theme_font_size_override("font_size", 15)
	debug_overlay.add_theme_color_override("font_color", Color(0.9, 0.96, 1.0, 0.96))
	debug_overlay.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	debug_overlay.add_theme_constant_override("outline_size", 6)
	ui_layer.add_child(debug_overlay)

	fuel_bar = menu.add_progress_bar("Fuel", 100.0)
	oxygen_bar = menu.add_progress_bar("Oxygen", 100.0)
	temp_bar = menu.add_progress_bar("Temperature", 100.0)

	menu.add_separator()
	menu.add_section("Quality")
	menu.add_option_button("Performance preset",
		PERFORMANCE_PRESET_NAMES, _performance_preset, _set_performance_preset)
	_preset_status_label = menu.add_label("")
	_preset_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var pool_quality_names: Array[String] = []
	for budget in FireGpuSolver.POOL_BUDGETS:
		pool_quality_names.append("%d tiles" % budget)
	menu.add_option_button("Pool budget", pool_quality_names,
		FireGpuSolver.POOL_BUDGETS.find(solver.pool_budget), _set_quality)

	menu.add_separator()
	wood_section = menu.add_section("Wood")
	wood_group = menu.add_group()
	wood_label = menu.add_label("0 logs")
	wood_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wood_bar = menu.add_progress_bar("Volatiles left", 100.0)
	menu.add_slider("Log fuel (kg)", 0.2, 12.0, wood_pile.log_fuel,
		func(v: float): wood_pile.log_fuel = v)
	# NON-PAPER: how hard the bed shelters its flame base from the wind (see
	# wood_shelter_rate). Higher keeps the flame anchored in a stronger breeze.
	menu.add_slider("Bed shelter (1/s)", 0.0, 20.0, solver.wood_shelter_rate,
		func(v: float): solver.wood_shelter_rate = v)
	menu.end_group()

	menu.add_separator()
	flamethrower_section = menu.add_section("Flamethrower")
	flamethrower_group = menu.add_group()
	menu.add_slider("Reach (m)", 1.0, 12.0, solver.torch_length,
		func(v: float): solver.torch_length = v)
	menu.add_slider("Fuel rate", 0.0, 5.0, solver.torch_rate,
		func(v: float): solver.torch_rate = v)
	menu.add_slider("Gas temperature (K)", 300.0, 1500.0, solver.torch_temperature,
		func(v: float): solver.torch_temperature = v)
	menu.add_slider("Jet speed (m/s)", 1.0, 20.0, solver.torch_speed,
		func(v: float): solver.torch_speed = v)
	menu.end_group()

	menu.add_separator()
	gas_section = menu.add_section("Gas")
	gas_group = menu.add_group()
	var fuel_names := []
	for f in FireGpuSolver.FUELS:
		fuel_names.append(f["name"])
	menu.add_option_button("Gas", fuel_names, solver.fuel_index,
		func(idx: int) -> void:
			_gas_fuel_index = idx
			solver.fuel_index = idx)
	menu.add_option_button("A units", ["CGS (Westbrook-Dryer)", "SI as printed"],
		solver.units_convention,
		func(idx: int) -> void: solver.units_convention = idx)
	menu.add_slider("Fuel supply", 0.0, 5.0, emitter_rate,
		func(v: float): emitter_rate = v)
	menu.end_group()

	_mode_button = menu.add_action_toggle("⛽", "Gas / Wood", true,
		func(on: bool) -> void: _set_fuel_mode(on))
	menu.add_action("↺", "Reset", _reset_simulation)
	_log_button = menu.add_action("🪵", "Log", _drop_log)
	_gas_reinjection_button = menu.add_action_toggle("🫧", "Continuous gas", gas_reinjection_enabled,
		_set_gas_reinjection)
	_ignite_button = menu.add_action("🔥", "Ignite", _ignite_gas)
	_flamethrower_button = menu.add_action_toggle("🔥", "Flamethrower", false,
		_set_flamethrower)
	var water_icons := ["💧", "💦", "🌊"]
	for level in [1, 2, 3]:
		var level_name: String = ["Light", "Med", "Heavy"][level - 1]
		_water_buttons[level] = menu.add_action_toggle(water_icons[level - 1], level_name, false,
			func(on: bool) -> void: _set_water_level(level, on))
	menu.add_action("🪣", "Pour", _pour_water)
	menu.add_action_toggle("🌬", "Wind", false, func(on: bool) -> void:
		_wind_enabled = on
		_apply_wind())
	menu.add_action_toggle("🧯", "Smother", false, func(on: bool) -> void:
		is_smothering = on)
	menu.add_debug_toggle("🐛", "Debug info", debug_info, func(on: bool) -> void:
		debug_info = on
		solver.profiling = on
		water.profiling = on
		debug_overlay.visible = on)

	# Ranges below are the paper's own (Fire-X Tab. 3) wherever it gives one.
	menu.add_separator()
	menu.add_section("Combustion")
	menu.add_slider("Heat efficiency φ", 0.0, 1.0, solver.heat_efficiency,
		func(v: float): solver.heat_efficiency = v)
	menu.add_slider("Radiation coeff", 0.0, 6.0, solver.radiation_coefficient,
		func(v: float): solver.radiation_coefficient = v)
	menu.add_slider("CO₂ coeff", 0.0, 10.0, solver.co2_coefficient,
		func(v: float): solver.co2_coefficient = v)
	menu.add_slider("Water vapor coeff", 0.0, 10.0, solver.h2o_coefficient,
		func(v: float): solver.h2o_coefficient = v)
	menu.add_slider("Residual coeff", 0.0, 10.0, solver.residual_coefficient,
		func(v: float): solver.residual_coefficient = v)
	menu.add_slider("Emitter temp (K)", 300.0, 1500.0, solver.emitter_temperature,
		func(v: float): solver.emitter_temperature = v)

	menu.add_separator()
	menu.add_section("Evaporation")
	menu.add_toggle("Evaporation", solver.evaporation_enabled, func(on: bool) -> void:
		solver.evaporation_enabled = on
		water.evaporation_active = on)
	menu.add_slider("Droplet diameter (mm)", 0.5, 5.0,
		solver.droplet_diameter * 1000.0,
		func(v: float): solver.droplet_diameter = v * 0.001)
	# UNDEFINED IN PAPER: Eq. 10's k, read as a heat transfer coefficient.
	menu.add_slider("Droplet heat transfer", 0.0, 500.0, solver.droplet_heat_transfer,
		func(v: float): solver.droplet_heat_transfer = v)
	# NON-PAPER: wet-cell combustion suppression. Below ~20 water makes the fire
	# spread instead of die; see FireGpuSolver.water_suppression.
	menu.add_slider("Water suppression", 0.0, 100.0, solver.water_suppression,
		func(v: float): solver.water_suppression = v)
	# NON-PAPER: how fast a cold puddle drains away so the fire can recover; 0 keeps
	# the old behaviour where water pooled forever and half-smothered the flame.
	menu.add_slider("Water drain (1/s)", 0.0, 1.0, solver.liquid_drain_rate,
		func(v: float):
			solver.liquid_drain_rate = v
			water.drain_rate = v)
	# Manual overrides cover the gameplay jet presets above.
	menu.add_slider("Jet velocity (m/s)", 0.0, 20.0, water.jet_velocity,
		func(v: float): water.jet_velocity = v)
	menu.add_slider("Jet frequency (Hz)", 10.0, 4000.0, water.jet_frequency,
		func(v: float): water.jet_frequency = v)

	menu.add_separator()
	menu.add_section("Flow")
	menu.add_slider("Vorticity strength", 0.0, 50.0, solver.vorticity_strength,
		func(v: float): solver.vorticity_strength = v)
	menu.add_slider("Turbulence Cs", 0.0, 0.4, solver.smagorinsky_cs,
		func(v: float): solver.smagorinsky_cs = v)
	menu.add_slider("Buoyancy g", 0.0, 20.0, solver.gravity,
		func(v: float): solver.gravity = v)
	# Free stream at the 10 m reference height; the fire sits deep in the boundary
	# layer under it (see wind_profile in fire_forces.comp).
	menu.add_slider("Wind X @10 m", -5.0, 5.0, _wind_vector.x,
		func(v: float):
			_wind_vector.x = v
			_apply_wind())
	menu.add_slider("Wind Z @10 m", -5.0, 5.0, _wind_vector.z,
		func(v: float):
			_wind_vector.z = v
			_apply_wind())

	menu.add_separator()
	menu.add_section("Performance")
	var pressure_slider := menu.add_slider("Pressure iterations", 16.0, 128.0,
		float(solver.pressure_iterations),
		func(v: float): solver.pressure_iterations = int(v))
	pressure_slider.step = 2.0
	_register_performance_control("pressure", pressure_slider,
		func(v: float): solver.pressure_iterations = int(v))
	# Entry order is the enum order, not the quality order: the third mode was
	# appended so that a preset storing 0 or 1 keeps meaning what it meant.
	var advection_option := menu.add_option_button("Advection",
		["MacCormack", "Semi-Lagrangian", "MacCormack (scalars)"],
		solver.advection_mode, _set_advection_mode)
	_register_performance_control("advection", advection_option, _set_advection_mode)
	var vorticity_option := menu.add_option_button("Vorticity mode",
		["Full", "Reduced", "Off"], solver.vorticity_mode, _set_vorticity_mode)
	_register_performance_control("vorticity_mode", vorticity_option, _set_vorticity_mode)
	var vorticity_frequency := menu.add_slider("Vorticity frequency", 1.0, 4.0,
		float(solver.vorticity_interval),
		func(v: float): solver.vorticity_interval = int(v))
	vorticity_frequency.step = 1.0
	_register_performance_control("vorticity_frequency", vorticity_frequency,
		func(v: float): solver.vorticity_interval = int(v))
	var simulation_rate_names := ["5 Hz", "10 Hz", "15 Hz", "30 Hz", "60 Hz", "120 Hz"]
	var simulation_rate := menu.add_option_button("Simulation rate", simulation_rate_names,
		SIMULATION_RATES.find(solver.simulation_hz), _set_simulation_hz)
	_register_performance_control("simulation_hz", simulation_rate, _set_simulation_hz)
	var temporal_interpolation := menu.add_toggle("Temporal interpolation",
		_temporal_interpolation, _set_temporal_interpolation)
	_register_performance_control("temporal", temporal_interpolation,
		_set_temporal_interpolation)
	var catchup := menu.add_slider("Max catch-up substeps", 1.0, 4.0,
		float(solver.max_catchup_steps), _set_max_catchup_steps)
	catchup.step = 1.0
	_register_performance_control("catchup", catchup, _set_max_catchup_steps)
	var water_substeps := menu.add_slider("Water SPH substeps", 4.0, 16.0,
		float(_water_substeps), _set_water_substeps)
	water_substeps.step = 1.0
	_register_performance_control("water_substeps", water_substeps, _set_water_substeps)
	var water_adaptive := menu.add_toggle("Adaptive water substeps",
		_water_adaptive_substeps, _set_water_adaptive_substeps)
	_register_performance_control("water_adaptive", water_adaptive,
		_set_water_adaptive_substeps)
	var water_cap := menu.add_slider("Water particle cap", 1024.0, 16384.0,
		float(_water_particle_cap), _set_water_particle_cap)
	water_cap.step = 1024.0
	_register_performance_control("water_cap", water_cap, _set_water_particle_cap)
	var march_step := menu.add_slider("Volume march step", 0.25, 4.0, 0.75,
		func(v: float): _set_volume_parameter("march_step", v))
	march_step.step = 0.05
	_register_performance_control("march_step", march_step,
		func(v: float): _set_volume_parameter("march_step", v))
	var march_budget := menu.add_slider("Volume march budget", 64.0, 512.0, 320.0,
		func(v: float): _set_volume_parameter("march_budget", int(v)))
	march_budget.step = 8.0
	_register_performance_control("march_budget", march_budget,
		func(v: float): _set_volume_parameter("march_budget", int(v)))
	var march_distance := menu.add_slider("Volume max distance", 16.0, 128.0, 80.0,
		func(v: float): _set_volume_parameter("max_distance", v))
	march_distance.step = 1.0
	_register_performance_control("march_distance", march_distance,
		func(v: float): _set_volume_parameter("max_distance", v))
	var water_scale := menu.add_slider("Water render scale", 0.25, 1.0, 1.0,
		_set_water_render_scale)
	water_scale.step = 0.05
	_register_performance_control("water_scale", water_scale, _set_water_render_scale)
	var render_scale := menu.add_slider("Global render scale", 0.4, 1.0, 1.0,
		_set_render_scale)
	render_scale.step = 0.05
	_register_performance_control("render_scale", render_scale, _set_render_scale)
	var msaa := menu.add_option_button("Anti-aliasing", MSAA_NAMES,
		MSAA_MODES.find(get_viewport().msaa_3d), _set_msaa)
	_register_performance_control("msaa", msaa, _set_msaa)
	var volume_half := menu.add_toggle("Half-res volume pass", _volume_half_res,
		_set_volume_half_res)
	_register_performance_control("volume_half", volume_half, _set_volume_half_res)
	# Apply the default preset rather than only labelling it. Every slider above was
	# built with the Reference value baked into its constructor, so a demo that never
	# applied its own default ran the reference configuration whatever the preset
	# selector said it was.
	_set_performance_preset(_performance_preset)


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


## MSAA lives on the root viewport, which outlives this demo, so the mode this
## scene found is remembered and put back in _exit_tree — otherwise a walk through
## the fire demo would leave every other demo un-antialiased.
func _set_msaa(index: int) -> void:
	var vp := get_viewport()
	if _msaa_entry_mode < 0:
		_msaa_entry_mode = vp.msaa_3d
	vp.msaa_3d = MSAA_MODES[clampi(index, 0, MSAA_MODES.size() - 1)]
