class_name FluidMaterial
extends RefCounted
## Constants that make each FluidKind behave and read differently. This is the
## single source of truth: FluidSystem._configure_solver() copies these onto the
## solver, which packs the derived values into the push constant and the
## SceneParams block. No per-material magic numbers live in the shaders or in
## any other script.

var viscosity := 0.14
var cohesion := 0.0
var collision_damping := 0.15
## Honey-only stretch term, applied in the pressure pass (0 = no kernel work).
var extension_strength := 0.0
var density_kg_m3 := 1000.0
var radius := 0.16
var emission_cycle_seconds := 24.0

# Derived kernel constants. The shaders read these back out of the
# SceneParams block (or the scaled push-constant field) instead of
# re-deriving them from the material id, so a mercury-only formula exists
# exactly once -- here.
## Pressure stiffness multiplier: mercury's dense equation of state, 1 elsewhere.
var stiffness_scale := 1.0
## Multiplier baked into the packed cohesion so the mercury look needs no
## shader-side branch.
var cohesion_kernel_scale := 1.0
## Extra AABB collision skin in resolve_scene_collisions; mercury's meniscus
## rides wider than the other liquids.
var collision_inflation := 0.14


static func for_kind(kind: int) -> FluidMaterial:
	var spec := FluidMaterial.new()
	match kind:
		FluidSystem.FluidKind.WATER:
			spec.cohesion = 400.0
		FluidSystem.FluidKind.LAVA:
			spec.viscosity = 0.3
			spec.cohesion = 800.0
			spec.collision_damping = 0.1
		FluidSystem.FluidKind.MERCURY:
			spec.viscosity = 0.2
			spec.cohesion = 6000.0
			spec.collision_damping = 0.08
			spec.density_kg_m3 = 13534.0
			spec.radius = 0.23
			spec.emission_cycle_seconds = 60.0
			spec.stiffness_scale = sqrt(sqrt(13534.0 / 1000.0))
			spec.cohesion_kernel_scale = 4.0
			spec.collision_inflation = 0.20
		FluidSystem.FluidKind.HONEY:
			spec.viscosity = 1.6
			spec.cohesion = 9000.0
			spec.collision_damping = 0.02
			spec.extension_strength = 24.0
			spec.radius = 0.24
			spec.emission_cycle_seconds = 60.0
		FluidSystem.FluidKind.WATER_OIL:
			spec.viscosity = 0.14
			spec.cohesion = 250.0
			spec.collision_damping = 0.15
			spec.density_kg_m3 = 850.0
	return spec
