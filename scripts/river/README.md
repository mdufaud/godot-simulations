# River integration

Godot 4.6, Forward+ or Mobile with RenderingDevice compute. Guided flow also works without compute. Units are meters and seconds; all samples use world X/Z coordinates. This is an authored visual shallow-water model, not a hydraulic engineering solver.

Copy `scripts/river/` (except the playground-specific `river_quality_profile.gd`), `shaders/river/`, and the three self-contained GPU helpers `scripts/core/shader_cache.gd`, `scripts/core/gpu_preflight.gd` and `scripts/core/gpu_timings.gd`, preserving their `res://` paths. There are no autoloads, UI scripts, ocean assets, or demo terrain scripts in the core. Supply your own normal, foam and bed textures; with a single foam texture, assign it to `foam_filaments` and leave `foam_bubbles` null.

```gdscript
var river := RiverSystem.new()
river.config = RiverConfig.new()
river.field = RiverField.new()
river.field.domain_m = Vector2(64.0, 96.0)
river.field.origin_m = Vector2(512.0, -128.0)
river.camera = get_viewport().get_camera_3d()
river.scene_world = river.camera.get_world_3d()
river.compute_available = RenderingServer.get_rendering_device() != null
river.micro_normal = load("res://water/normal.png")
river.foam_filaments = load("res://water/filaments.png")
river.foam_bubbles = load("res://water/bubbles.png")
river.riverbed_albedo = load("res://water/pebbles.png")
river.loading_stage = func(label: String) -> void: print(label)
add_child(river)
river.start()
```

`loading_stage` is optional: during `start()` and blocking bakes it is called with a stage name, and with an empty string while waiting, so a loading screen can redraw.

## Field

The domain is the rectangle `field.domain_rect()`, `domain_m` wide and centred on `field.origin_m`. Define your river with a `RiverField` subclass implementing `sample_bed(point)`, `sample_height(point, level_m)` and `sample(point, level_m)`. The flow sample is `(normalized_velocity_x, normalized_velocity_z, foam_source, wet_mask)`; it is multiplied by `RiverConfig.speed_m_s`. `sample_solver()` may override `sample()` to supply an unobstructed driving current: SWE resolves the stamped solids itself, while the guided renderer can retain prepared obstacle deflections. `RiverLandscape` in the demo is an example; the core has a flat straight-channel default.

Prepared images replace every CPU sampling loop:

- `field.solver_terrain_image`: RGBAF over the domain, `(bed_height_m, reference_surface_height_m, normalized_velocity_x, normalized_velocity_z)`, heights without the water-level offset. Include solid footprints in the bed channel; otherwise `obstacle_meshes` are stamped during the first procedural sampling. Set it to null before restarting after changing fixed terrain or rocks.
- `field.flow_image` (RGBA float: flow sample above) and `field.bed_image` (RGB float: `bed_height_m`, `surface_height_m` including `water_level_m`, shore-fade weight 0..1): uploaded as given by `bake()`. Also set `field.height_range_m` to the surface height range so the water surface gets correct culling bounds.

A domain with no wet texel idles: the surface is hidden and the solver, foam and reflections stop.

## Spilling

Set `field.spills` to let water leave the height field wherever the bed drops steeper than `SPILL_SLOPE` across a cell face while the water below stays under the upper bed (rule of Chentanez & Müller). That face becomes a wall for the cell below; the outflow of the cell above is carried by GPU particles that fall, slide down faces steeper than the spill slope, and give their volume and horizontal momentum back to the cell they land in. Stamped rocks are part of the bed, so water pours off them too. On a spilling field, slopes are not balanced as terraces: steps spill and ramps accelerate their water, and the level guidance lets go where the current runs well above the guided one, so a fall carries what flows in instead of what the guidance pumps. The bookkeeping is kept in exact volume units: what spills equals what lands plus what is still in flight.

`RiverSystem` draws the particles through `ScreenSpaceFluidRenderer`: a sheet stays clear near its lip and aerates with its drop over Horeni's break-up length of the measured discharge per metre of lip, more so the higher `RiverConfig.whitewater_strength`. A stream thinner than that mean breaks up sooner by the same law and draws only its share of particles, foamy water leaves already aerated in proportion to its foam, and water that slid down a face is drawn broken up. Spray, mist and splashes follow the landing and rock-hit points the particles report, weighted by how far each landing fell; landings on touching 1 m tiles form an impact zone, and each of up to eight zones gets its own spray, so a terrain with many lips needs no per-lip setup. The water surface mesh then has one vertex per solver cell, whatever `surface_cell_size_m`, so the two pools of a spill face meet on it. Set `field.reflection_pools` with two reflection planes to mirror each pool (water zones 1 and 2) at its anchor. Spilling fields always run the live solver over the whole domain and do not support moving domains. The solver's snapshot exposes `spill_particles`, `spill_state`, `spill_deposits` and `spill_positions`.

## Moving domain

`river.move_domain(origin_m)` recentres the domain without `stop()`/`start()`. Assign the new prepared images to the field first. The solver keeps its state in world coordinates: overlapping cells carry over, new cells start from the guided field, and foam history is shifted.

## Rocks

Rocks are the `MeshInstance3D`s in `field.obstacle_meshes`; their upper surface is stamped into the solver bed. To add a rock at runtime, append its meshes to `field.obstacle_meshes` and call `river.obstacles_added(meshes)`: the bed updates without resetting the water. This is not supported with a moving solver window.

## Simulation window and level of detail

By default the SWE solver covers the whole domain at `river.swe_cell_m` (0.125 m). Set `river.swe_window_m` (for example `Vector2(16.0, 24.0)`, axis-aligned) before `start()` to simulate only a window inside a larger guided domain. The window follows the camera's view of the water, snaps in 4 m steps and reprojects overlapping state; outside it, the guided field draws the river. `river.swe_range_m` (0 = always) stops the solver when no wet water of the window is within that distance of the camera: the surface fades to guided flow over about 1 s, and on return the solver reseeds, warms up for 0.5 s and fades back in. Spilling fields always simulate the whole domain.

Steep or diagonal channels need stronger guidance than the playground's near-flat river. `RiverConfig.current_guidance_hz` (default 0.2) and `level_guidance_hz` (default 0.6) relax the current and depth towards the guided field; At 0.85 m/s, 1 and 5 Hz hold 3 m wide, 0.3 m deep channels with a bend at 5–30 % grade in every direction; at 2 m/s, 2 and 10 Hz. Higher values look more guided and less dynamic.

`frozen` stops simulation, `reset()` reseeds it, `swe.set_enabled(false/true)` switches to guided flow, and `start()`/`stop()` are idempotent. `apply_config()` accepts a runtime resource; duplicate shared preset resources before editing.

## Rendering

The render knobs (mesh cell size, foam size, reflection scale/plane count, surface detail) are independent of the solver. A `reflection_scale` of 0 builds no reflection updates. These water material parameters are off by default; set them on `river.water_material` after `start()`:

- `lit_body`: the water colour is lit as albedo and only the transmission is emitted, so shaded water does not glow.
- `deep_tint`, `deep_tint_depth_m`: the body colour turns from `deep_color` to `deep_tint` as the prepared depth goes from x to y.
- `body_min_thickness_m`: wet water is tinted as if at least this thick.
- `shore_fade_depth_m`, `shore_soft_thickness_m`: soften the shoreline by prepared depth and by the visible thickness, weighted by the bed image's third channel.
- `domain_edge_fade_m`: fade the surface out near the domain border, where another water takes over.
- `guided_coverage`: inside the solver window, cells the simulation leaves dry but the prepared field marks wet draw the guided water instead of a hole.

## Queries and floating bodies

`submit_queries(PackedVector2Array)` accepts at most 32 points and returns false while a batch is outstanding. Poll `take_query_batch()` without blocking. The returned dictionary contains the submitted points and a packed float array of `(height_m, velocity_x_m_s, velocity_z_m_s, depth_m)` for each point. GPU results arrive asynchronously; guided fallback uses the same API. Depth below 1.5 cm is dry. Queries sample the computed state inside the window and the prepared field outside it.

`river_buoyant_body.gd` consumes four samples through `set_water_samples()`. Call `probe_positions()` each physics tick, submit their X/Z coordinates, then apply the returned samples. It applies buoyancy and drag relative to the water current in `_integrate_forces()`. Add your own terrain/rock collision shapes and mesh, and freeze bodies when pausing the river. The demo's `RiverInteractions` shows capped spawning, query ownership and pause handling. Bodies are driven by water; they do not displace the solver.

## Reflections and scenery

Planar reflections exclude water on render layer 2. For custom scenery clipping/wetness, include `scenery_clip.gdshaderinc` in scenery shaders, register those materials in `scenery_materials`, and bind their river height/domain/origin/plane parameters as shown in `river_scenery.gd`. With multiple terraces, set `field.reflection_anchors_m`, `terrace_heights_m`, and `surface_slope`. Reflection planes assume a near-flat surface sloping along Z.

## Solver

The finite-volume HLL solver transports momentum and foam with wet/dry handling. The reference surface gradient is balanced so authored river drops do not collapse into a different global water level. Current and level guidance maintain the authored driving flow; local obstacle responses remain dynamic. At the simulation boundary, inflow edges are restored to the guided state and outflow edges transmit departing water, in any flow direction. Solver time is capped per frame to prevent unbounded work after a stall.

`tests/probe.sh river_slope` measures the steep-channel criteria and `tests/probe.sh river_domain` the window, `move_domain`, level of detail and idle behaviour.
