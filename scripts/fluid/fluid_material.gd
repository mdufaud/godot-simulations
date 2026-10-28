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
## Bingham yield stress (Pa); 0 = flows freely. Solved implicitly with
## Papanastasiou regularisation (shaders/sph/sph_viscosity.comp). At the default
## SphFluidSolver.YIELD_SWEEPS a settled pile stands within 2% of the fully
## converged height up to 300 Pa and 5% lower at 400 Pa (the slider's top);
## stiffer yields need more sweeps.
var yield_stress := 0.0
## Water + Oil only: drift relaxation time (s) of the two-phase mixture model
## (Ren et al. 2014). Below the particle scale oil slips past water at
## u = tau * g * (1000 - density_kg_m3) / rho_mixture; 0 = no slip. 0.3 s gives
## an isolated oil parcel 0.48 m/s, about the terminal rise of an oil blob one
## particle spacing (12 cm) across at drag coefficient ~1.
var drift_relaxation_s := 0.0
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
## Lava only: heat below which a particle stiffens into crust and stops flowing
## (0 = never). Packed into SceneParams.fluid_material.w.
var freeze_heat := 0.0


static func for_kind(kind: int) -> FluidMaterial:
	var spec := FluidMaterial.new()
	match kind:
		FluidSystem.FluidKind.WATER:
			spec.cohesion = 400.0
		FluidSystem.FluidKind.LAVA:
			spec.viscosity = 1.0
			spec.cohesion = 800.0
			spec.collision_damping = 0.1
			spec.freeze_heat = 0.2
		FluidSystem.FluidKind.FLUID_LAVA:
			spec.viscosity = 0.03
			spec.cohesion = 800.0
			spec.collision_damping = 0.1
			spec.freeze_heat = 0.2
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
			spec.drift_relaxation_s = 0.3
		FluidSystem.FluidKind.ASTRAL:
			spec.viscosity = 0.25
			spec.cohesion = 1200.0
			spec.collision_damping = 0.05
			spec.radius = 0.18
		FluidSystem.FluidKind.SPECTRAL_GEL:
			spec.viscosity = 1.0
			spec.cohesion = 1500.0
			spec.collision_damping = 0.28
			spec.extension_strength = 3600.0
			spec.radius = 0.22
			spec.emission_cycle_seconds = 60.0
		FluidSystem.FluidKind.PRISMATIC_SLIME:
			spec.viscosity = 2.6
			spec.yield_stress = 120.0
			spec.cohesion = 1800.0
			spec.collision_damping = 0.06
			spec.radius = 0.22
			spec.emission_cycle_seconds = 48.0
		FluidSystem.FluidKind.LIGHT_PASTE:
			spec.viscosity = 0.45
			spec.yield_stress = 300.0
			spec.cohesion = 2200.0
			spec.collision_damping = 0.03
			spec.radius = 0.23
			spec.emission_cycle_seconds = 72.0
		FluidSystem.FluidKind.LIQUID_NITROGEN:
			spec.viscosity = 0.05
			spec.cohesion = 300.0
			spec.collision_damping = 0.35
			spec.density_kg_m3 = 808.0
	return spec
