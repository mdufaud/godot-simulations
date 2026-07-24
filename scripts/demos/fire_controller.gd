extends Node3D
## Fire Demo Controller — Fire-X combustion, volumetrically raymarched.

const FireWater = preload("res://scripts/fire/fire_water.gd")
##
## The solver lives entirely in RenderingDevice textures (see FireGpuSolver);
## this node queues grid emitters, binds the display volume to the shader and
## drives the light and UI from the solver's reduced stats.
##
## Fire-X: Wrede et al., ACM TOG 44(6) art. 268 (SIGGRAPH Asia 2025).
##
## The campfire scene stays visible while fuel switches between the central gas
## pipe and the wood bed. Water leaves the camera and is aimed by looking.

# --- Node references ---
@onready var fire_volume: MeshInstance3D = $FireVolume
@onready var spark_particles: GPUParticles3D = $SparkParticles
@onready var fire_light: OmniLight3D = $FireLight
@onready var player: FpsWalker = $Player
@onready var gas_pipe: Node3D = $Campfire/GasPipe
@onready var wood_pile: WoodPile = $Campfire/WoodPile
@onready var menu: SimMenu = $UI/SimMenu

var stats_label: Label
var probe_label: Label
var timing_label: Label
var debug_info := false
var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar
var wood_bar: ProgressBar
var wood_label: Label
var wood_group: VBoxContainer
var gas_group: VBoxContainer
var wood_section: Button
var gas_section: Button

var solver: FireGpuSolver
var water: FireWater
var volume_material: ShaderMaterial
var volume_texture: Texture3DRD
var indir_texture: Texture3DRD
var texture_bound := false
## The sparse build's field is a tile atlas rather than the domain, so it needs a
## raymarcher that resolves through the pool's indirection volume.
const SPARSE_VOLUME_SHADER := "res://shaders/fire/fire_sparse.gdshader"

var fluid_renderer: ScreenSpaceFluidRenderer

# --- Fuel mode ---
var gas_mode := true
var _gas_fuel_index := 0
var gas_reinjection_enabled := true
const CAMPFIRE_SPAWN := Vector3(0.0, 1.2, 4.0)
var _mode_button: Button
var _log_button: Button
var _gas_reinjection_button: Button
var _ignite_button: Button

# --- Quality presets ---
## Physical extent of the simulated box, held constant across presets so the
## flame keeps the same size on screen and only the resolution moves.
## The walls used to cut through the camp: the seat logs sit at r ~ 3.2 m and the
## boulders at r ~ 5-6 m, both outside the old 6.4 m box, and the smoke visibly
## piled up against a 9.6 m ceiling. Doubled on every axis so the plume leaves the
## domain through open air rather than through a wall.
const DOMAIN_SIZE := Vector3(12.8, 19.2, 12.8)
## Cell size per preset. Tab. 3 allows 0.1-10.0 m, and 0.1 is the flame fidelity
## the domain was sized around; the coarser two exist because the domain grew 8x
## in volume at fixed cell size.
##
## Cost is cubic in the inverse: doubling the cell is 8x fewer cells for ~8x less
## GPU time, and the Jacobi pressure loop alone is half of it.
const QUALITY_CELLS := [0.4, 0.2, 0.1]
const QUALITY_NAMES := ["Low (32x48x32)", "Medium (64x96x64)", "High (128x192x128)"]
const POOL_BUDGETS := [1024, 1536, 2048]
const POOL_QUALITY_NAMES := ["Low (1024 tiles)", "Medium (1536 tiles)", "High (2048 tiles)"]

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
## Both the hose and the bucket leave the player's camera, so the aim is wherever
## they are looking rather than a fixed nozzle bolted into the scene.
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
# Rates are 4x what they were when a parcel weighed 0.1 kg; FireWater.DROPLET_MASS
# is now 0.025 kg, so the delivered kg/s per preset is unchanged and only the
# rendered density went up.
const WATER_PRESETS := {
	1: {"freq": 880.0, "vel": 4.0, "spray": 0.0},   # Light  — thin steady stream, hisses, survives
	2: {"freq": 1680.0, "vel": 6.0, "spray": 0.0},  # Medium — solid column, big steam, strong knockdown
	3: {"freq": 2800.0, "vel": 8.0, "spray": 0.0},  # Heavy  — torrent
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
	# Sparse tile grid instead of the fixed box, for the A/B runs. It has to be set
	# before init_render is queued: it selects the shader variant, the texture
	# extents and the dispatch mode on the solver, and the raymarcher here.
	solver.sparse = "--sparse" in OS.get_cmdline_user_args()
	volume_material = fire_volume.material_override as ShaderMaterial
	if volume_material:
		_setup_volume_material()

	RenderingServer.call_on_render_thread(solver.init_render)

	# P3/P4: SPH water droplets and their coupling to the grid. The screen-space
	# surface only reconstructs where droplets pack tight, so the budget is large
	# enough to keep both a dense in-flight column and a connected floor puddle
	# alive at once — a smaller budget starves the stream into falling beads.
	water = FireWater.new()
	water.particle_count = 16384
	water.evaporation_active = solver.evaporation_enabled
	# Queued as a closure rather than bound: the pool's indirection volume does not
	# exist until the solver's own queued init_render has run on the render thread,
	# so binding it here would capture an invalid RID. The droplets keep the dense
	# box as their own SPH domain either way — only the fire grid became the map.
	var sph_box := Vector3(solver.grid_dims) * solver.cell_size
	RenderingServer.call_on_render_thread(func() -> void:
		water.init_render(solver.sim_dims(), solver.cell_size,
			solver.indirection_rid(), sph_box))

	_setup_fluid_renderer()
	_build_wood_bed()
	_setup_ui()
	_set_fuel_mode(false)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		volume_texture = Texture3DRD.new()
		volume_texture.texture_rd_rid = solver.get_display_tex_rid()
		if volume_material:
			volume_material.set_shader_parameter("volume_tex", volume_texture)
			# Sparse: the display field is an atlas of resident tiles, so the shader
			# also needs the map from virtual tile to atlas slot to read it.
			if solver.sparse:
				indir_texture = Texture3DRD.new()
				indir_texture.texture_rd_rid = solver.indirection_bytes_rid()
				volume_material.set_shader_parameter("indir_tex", indir_texture)
		fire_volume.visible = true
		texture_bound = true
	if solver.sparse and volume_material:
		# The resident set moves with the fire, so the ray clip has to follow it.
		var clip := solver.display_clip_box()
		volume_material.set_shader_parameter("clip_min", clip.position)
		volume_material.set_shader_parameter("clip_max", clip.end)

	# Last frame's reduction, read up front: the wood bed is driven by the per-log
	# gas temperatures in it, and its emitters have to be uploaded before the
	# solver steps.
	var stats := solver.get_stats()
	var aim := _aim()

	# Rates are per simulated second, so they must follow the solver's clock and
	# not the frame delta — see FireGpuSolver.sim_delta.
	var sim_dt := solver.sim_delta(delta)
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
		if jet_enabled:
			_aim_hose(aim)
			# Simulated time, not frame time: emitting per wall-clock second makes
			# the droplet count a function of the frame rate, and two runs of the
			# same nozzle then disagree by a couple of hundred kelvin.
			RenderingServer.call_on_render_thread(water.emit_jet.bind(sim_dt, delta))
		RenderingServer.call_on_render_thread(water.step_droplets.bind(delta))
		RenderingServer.call_on_render_thread(water.scatter_render)
		RenderingServer.call_on_render_thread(water.gather_render.bind(
			solver.get_texture_rid("liquid_scal"),
			solver.get_texture_rid("liquid_vel")))

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))

	if water.initialized:
		RenderingServer.call_on_render_thread(water.return_render)
		fluid_renderer.update(water.sph_position_tex_rid(), water.particles_active)

	_update_light(stats)
	_update_ui_stats(stats)
	if spark_particles:
		spark_particles.emitting = stats["max_reaction"] > 0.1


func _exit_tree() -> void:
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	if indir_texture != null:
		indir_texture.texture_rd_rid = RID()
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
	for level in _water_buttons:
		_water_buttons[level].set_pressed_no_signal(false)
		_water_buttons[level].visible = true
	wood_group.visible = not gas_mode
	wood_section.visible = not gas_mode
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

## Point the raymarcher at whichever grid the solver runs on.
##
## Dense marches the box at fixed steps. Sparse swaps in a shader that DDAs the
## tile pool's indirection volume instead: the box the ray is clipped against
## becomes the whole 409.6 x 102.4 x 409.6 m virtual domain, and the mesh has to
## grow with it — it is the proxy geometry the fragments come from, so a fire that
## walks out of the old 12.8 m box would simply have no pixels to be drawn into.
func _setup_volume_material() -> void:
	var box := Vector3(solver.sim_dims()) * solver.cell_size
	if solver.sparse:
		volume_material.shader = load(SPARSE_VOLUME_SHADER)
		volume_material.set_shader_parameter("cell_size", solver.cell_size)
		volume_material.set_shader_parameter("atlas_cells", Vector3(FireTilePool.ATLAS_CELLS))
		volume_material.set_shader_parameter("atlas_tiles", FireTilePool.ATLAS_TILES)
		volume_material.set_shader_parameter("virtual_tiles", FireTilePool.VTILES)
		(fire_volume.mesh as BoxMesh).size = box
		# cell_to_world puts the ground at y = 0 and centres x/z on the origin, so
		# the box mesh sits half its height up either way.
		fire_volume.position.y = box.y * 0.5
	volume_material.set_shader_parameter("box_size", box)
	# The blue reaction core fades over the height of the DENSE domain in both
	# builds; over the sparse one it would never fade at all.
	volume_material.set_shader_parameter("blue_height", DOMAIN_SIZE.y)
	# The volume stores temperature normalised against these, so the shader
	# needs them to turn the red channel back into kelvins.
	volume_material.set_shader_parameter("ambient_temperature", solver.ambient_temperature)
	volume_material.set_shader_parameter("display_temperature", solver.display_temperature)
	# Nothing to march until the solver's textures exist: an unbound sampler falls
	# back to Godot's default texture, which for the indirection volume is not even
	# the right format to read.
	fire_volume.visible = false


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
	# The SPH rest spacing is ~0.1 m and only a sparse monolayer of droplets ever
	# lands, so the impostor radius has to be well above the spacing for lone
	# droplets to fuse into one sheet instead of reconstructing as separate beads.
	# 0.14 (barely above spacing) still read as beads; 0.24 fuses the puddle.
	fluid_renderer.radius = 0.24
	fluid_renderer.mode = 0.0
	fluid_renderer.render_scale = 1.0
	# Matches the fire grid box so the surface MultiMesh is not frustum-culled.
	fluid_renderer.domain_aabb = AABB(Vector3(-0.5, 0.0, -0.5) * DOMAIN_SIZE, DOMAIN_SIZE)
	# Foam deferred: land the clean surface + puddle first.
	fluid_renderer.build_foam = false
	add_child(fluid_renderer)
	fluid_renderer.start()

	# The fire volume draws at render_priority 1; keep the water composite below it
	# so the flame column reads in front of the water at the base. Neither writes
	# depth, so this priority is what orders the two transparent layers.
	var cm := fluid_renderer.composite_material()
	cm.render_priority = 0
	# Dark night campfire: the default daytime sky reflection would light the water
	# bright blue. Near-black sky and no sun disc leave refraction + Fresnel rim as
	# the visible cues.
	cm.set_shader_parameter("sky_zenith", Color(0.02, 0.03, 0.05))
	cm.set_shader_parameter("sky_horizon", Color(0.04, 0.05, 0.06))
	cm.set_shader_parameter("sun_intensity", 0.0)
	# The composite is unshaded, so where the body is optically thick it outputs
	# tint_color directly; the demo default (teal 0.05,0.32,0.42) glows like
	# antifreeze against the black scene. A shallow campfire puddle should read as
	# clear water over wet ground, so the tint goes near-black and absorption drops
	# to keep the thin sheet refractive rather than filling with colour.
	cm.set_shader_parameter("tint_color", Color(0.015, 0.03, 0.04))
	cm.set_shader_parameter("absorption_scale", 0.15)


## The three water buttons are a radio group: turning one on selects that intensity
## and clears the others; turning the active one off stops the jet.
func _set_water_level(level: int, on: bool) -> void:
	if not on:
		if _water_level == level:
			jet_enabled = false
			_water_level = 0
		return
	_water_level = level
	jet_enabled = true
	var p: Dictionary = WATER_PRESETS[level]
	water.jet_frequency = p.freq
	water.jet_velocity = p.vel
	water.jet_spray_angle = p.spray
	for lv in _water_buttons:
		if lv != level:
			_water_buttons[lv].set_pressed_no_signal(false)


## The hose is held, so the nozzle follows the camera every frame. It starts just
## clear of the near plane: emitting at the eye itself puts the first slice of the
## stream inside the camera, where the screen-space surface fills the screen.
func _aim_hose(aim: Dictionary) -> void:
	water.jet_position = aim["origin"] + aim["direction"] * 1.0
	water.jet_direction = aim["direction"]


func _light_fire() -> void:
	if gas_mode:
		if gas_reinjection_enabled and emitter_rate > 0.0:
			solver.push_event(FireGpuSolver.EVENT_FUEL, emitter_position,
				emitter_radius, emitter_rate)
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


## A bucket thrown from where the player stands. The whole particle budget goes at
## once — the SPH solver has no streaming emitter, so a second throw replaces the
## first rather than adding to it.
##
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
	var aim := _aim()
	var origin: Vector3 = aim["origin"] + aim["direction"] * 1.0
	var throw: Vector3 = aim["direction"] * 8.0
	RenderingServer.call_on_render_thread(water.spawn_droplets.bind(
		mini(water.particle_count, 4000), origin, 0.9, throw))


## Swap dense field resolution or sparse pool budget.
##
## The display texture is freed on the render thread, so the binding is dropped
## and stepping suspended here, on the main thread, before the rebuild is queued.
## [member FireGpuSolver.initialized] comes back true at the end of the rebuild
## and [method _process] picks the new texture up on the next frame.
func _set_quality(index: int) -> void:
	var cell: float = QUALITY_CELLS[index]
	var dims := Vector3i((DOMAIN_SIZE / cell).round())
	var budget: int = POOL_BUDGETS[index] if solver.sparse else 0
	if (solver.sparse and budget == solver.pool_budget) \
			or (not solver.sparse and dims == solver.grid_dims):
		return

	solver.initialized = false
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	if indir_texture != null:
		indir_texture.texture_rd_rid = RID()
	fire_volume.visible = false
	texture_bound = false
	if solver.sparse:
		RenderingServer.call_on_render_thread(func() -> void:
			water.set_indirection_rid(RID())
			solver.set_resolution(dims, solver.cell_size, budget)
			water.set_indirection_rid(solver.indirection_rid()))
	else:
		RenderingServer.call_on_render_thread(solver.set_resolution.bind(dims, cell))
	if not solver.sparse:
		# A log emitter narrower than a couple of cells falls between them and injects
		# nothing at all on the coarse preset.
		wood_pile.emit_radius = maxf(1.3, cell * 2.0)
	_light_fire()


func _reset_simulation() -> void:
	RenderingServer.call_on_render_thread(solver.clear_fields)
	water.reset_droplets()
	RenderingServer.call_on_render_thread(water.clear_droplets)
	jet_enabled = false
	_water_level = 0
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

	if debug_info:
		stats_label.text = "T max: %d K | reaction %.2f mol/(m³·s)" % [
			int(max_temp), stats["total_reaction"]]
		if not gas_mode:
			stats_label.text += " | wood %d K" % int(wood_pile.hottest_surface())

		# Mass-fraction closure: a running check that species transport conserves
		# mass. Drifts away from 1.0 only if a product coefficient is off default.
		var timings := solver.get_timings()
		var probe_text := "ΣY = %.4f" % stats["mass_fraction_sum"]
		if water.mass_measured_once:
			probe_text += " | Σm_p %.3f kg" % water.measured_mass
		# The P4 criterion: the energy the gas loses has to be the latent plus
		# sensible heat the liquid gave up, to 1 %. Only shown once there is liquid
		# on the grid, since the ratio is 0/0 in a dry domain.
		if stats["energy_budget"] > 0.0:
			probe_text += " | ΔE err %.3f%%" % (stats["energy_residual"] * 100.0)
		if timings.has("total"):
			probe_text += " | GPU %.2f ms" % timings["total"]
		probe_label.text = probe_text
		timing_label.text = _format_timings(timings)

	fuel_bar.value = stats["avg_fuel"] * 100.0
	oxygen_bar.value = stats["avg_oxygen"] * 100.0
	temp_bar.value = clampf(temp_norm * 100.0, 0.0, 100.0)
	if not gas_mode:
		wood_bar.value = wood_pile.total_fuel() \
			/ maxf(wood_pile.initial_fuel(), 1e-4) * 100.0
		_refresh_wood_label()


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
	stats_label = menu.add_label("T max: 300 K")
	probe_label = menu.add_label("ΣY = 1.0000")
	timing_label = menu.add_label("")
	# Without this a Label reports its whole line as its minimum width, which
	# widens the panel past its anchored 300 px for as long as the text is set.
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	probe_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	timing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Debug readout is hidden until the Debug info toggle turns it on.
	stats_label.visible = false
	probe_label.visible = false
	timing_label.visible = false
	menu.add_separator()
	fuel_bar = menu.add_progress_bar("Fuel", 100.0)
	oxygen_bar = menu.add_progress_bar("Oxygen", 100.0)
	temp_bar = menu.add_progress_bar("Temperature", 100.0)

	menu.add_separator()
	menu.add_section("Quality")
	var quality_names := POOL_QUALITY_NAMES if solver.sparse else QUALITY_NAMES
	var quality_index := POOL_BUDGETS.find(solver.pool_budget) if solver.sparse \
		else QUALITY_CELLS.find(solver.cell_size)
	menu.add_option_button("Pool budget" if solver.sparse else "Resolution",
		quality_names, quality_index, _set_quality)

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
	menu.add_debug_toggle("🐛", "Debug info", false, func(on: bool) -> void:
		debug_info = on
		solver.profiling = on
		stats_label.visible = on
		probe_label.visible = on
		timing_label.visible = on)

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
		func(v: float): solver.liquid_drain_rate = v)
	# Both ranges are Tab. 3's own for the particle emitter.
	menu.add_slider("Jet velocity (m/s)", 0.0, 10.0, water.jet_velocity,
		func(v: float): water.jet_velocity = v)
	menu.add_slider("Jet frequency (Hz)", 10.0, 100.0, water.jet_frequency,
		func(v: float): water.jet_frequency = v)

	menu.add_separator()
	menu.add_section("Flow")
	menu.add_slider("Vorticity strength", 0.0, 50.0, solver.vorticity_strength,
		func(v: float): solver.vorticity_strength = v)
	menu.add_slider("Turbulence Cs", 0.0, 0.4, solver.smagorinsky_cs,
		func(v: float): solver.smagorinsky_cs = v)
	menu.add_slider("Buoyancy g", 0.0, 20.0, solver.gravity,
		func(v: float): solver.gravity = v)
	menu.add_slider("Pressure iters", 16.0, 128.0, float(solver.pressure_iterations),
		func(v: float): solver.pressure_iterations = int(v))
	menu.add_slider("Substeps", 1.0, 4.0, float(solver.substeps),
		func(v: float): solver.substeps = int(v))
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
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v
