# River integration

Godot 4.6, Forward+ or Mobile with RenderingDevice compute. Guided flow also works without compute. Units are meters and seconds; all samples use world X/Z coordinates, with the field centered at the world origin. This is an authored visual shallow-water model, not a hydraulic engineering solver.

Copy `scripts/river/` (except the playground-specific `river_quality_profile.gd`) and `shaders/river/`, preserving their `res://` paths. There are no required autoloads, UI scripts, ocean assets, or demo terrain scripts in the core. Supply your own normal, foam and bed textures.

```gdscript
var river := RiverSystem.new()
river.config = RiverConfig.new()
river.field = RiverField.new()
river.field.domain_m = Vector2(64.0, 96.0)
river.camera = get_viewport().get_camera_3d()
river.scene_world = river.camera.get_world_3d()
river.compute_available = RenderingServer.get_rendering_device() != null
river.micro_normal = load("res://water/normal.png")
river.foam_filaments = load("res://water/filaments.png")
river.foam_bubbles = load("res://water/bubbles.png")
river.riverbed_albedo = load("res://water/pebbles.png")
add_child(river)
river.start()
```

Define your river with a `RiverField` subclass implementing `sample_bed(point)`, `sample_height(point, level_m)` and `sample(point, level_m)`. The flow sample is `(normalized_velocity_x, normalized_velocity_z, foam_source, wet_mask)`. It is multiplied by `RiverConfig.speed_m_s`. `RiverLandscape` in the demo is an example; the core has a flat straight-channel default.

Alternatively supply `field.solver_terrain_image`: an RGBAF image covering `domain_m`, whose channels contain `(bed_height_m, reference_surface_height_m, normalized_velocity_x, normalized_velocity_z)`. Heights exclude the configurable water-level offset. The default field samples this image. Prepared images avoid the procedural setup cost. Include solid footprints in the bed channel; otherwise `obstacle_meshes` can be stamped during the first procedural bake. Cache invalidation is explicit: set the image to null before restarting after changing fixed terrain or rocks.

The solver follows the camera's intersection with the water, snapping its 16 × 24 m window in 4 m steps. It reprojects depth, momentum and foam into the new window rather than resetting overlapping cells. High/Ultra solve at 12.5 cm nearby; Medium or a camera farther than 24 m uses 25 cm cells and fewer substeps. Low, or a camera farther than 56 m, uses guided flow without advancing SWE. Outside the window, the guided field continues the river. This is one moving simulation window, not multiple coupled simulation cascades. The water mesh also becomes coarser away from the window. Solver time is capped per frame to prevent unbounded work after a stall.

Set `river.set_solver_quality(0..3)`, or switch with `river.swe.set_enabled(false/true)`. The render knobs (mesh cell size, foam size, reflection scale/plane count, surface detail) remain independent. `apply_config()` accepts a runtime resource; duplicate shared preset resources before editing. `frozen` stops simulation, `reset()` reseeds it, and `start()`/`stop()` are idempotent.

The finite-volume HLL solver transports momentum and foam with wet/dry handling. The reference surface gradient is balanced so authored river drops do not collapse into a different global water level. Current and level relaxation maintain the authored driving flow and prevent persistent drift at the simulation boundary; local obstacle responses remain dynamic. `sample_solver()` may override `sample()` to supply an unobstructed driving current: SWE resolves the stamped solids itself, while the guided renderer can retain prepared obstacle deflections. Outflow boundaries transmit departing water instead of forcing the initial velocity back onto it.

`submit_queries(PackedVector2Array)` accepts at most 32 points and returns false while a batch is outstanding. Poll `take_query_batch()` without blocking. The returned dictionary contains the submitted points and a packed float array of `(height_m, velocity_x_m_s, velocity_z_m_s, depth_m)` for each point. GPU results arrive asynchronously; guided fallback uses the same API. Depth below 1.5 cm is dry. Queries sample the computed state inside the window and the prepared field outside it.

`river_buoyant_body.gd` consumes four samples through `set_water_samples()`. Call `probe_positions()` each physics tick, submit their X/Z coordinates, then apply the returned samples. It applies buoyancy and drag relative to the water current in `_integrate_forces()`. Add your own terrain/rock collision shapes and mesh, and freeze bodies when pausing the river. The demo's `RiverInteractions` shows capped spawning, query ownership and pause handling. Bodies are driven by water; they do not displace the solver.

Planar reflections exclude water on render layer 2. For custom scenery clipping/wetness, include `scenery_clip.gdshaderinc` in scenery shaders, register those materials in `scenery_materials`, and bind their river height/domain/plane parameters as shown in `river_scenery.gd`. With multiple terraces, set `field.reflection_anchors_m`, `terrace_heights_m`, and `surface_slope`. Reflection cameras render cropped visible regions at the requested pixel density. The near-flat surface assumption still applies.
