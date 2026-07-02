class_name FireSimulationGrid
extends RefCounted
## Grid-based fire simulation inspired by Fire-X (Wrede et al., SIGGRAPH Asia 2025)
##
## Implements simplified multi-species reactive transport:
## - Fuel, Oxygen, Temperature, Smoke density per cell
## - Stoichiometry-dependent combustion with Arrhenius-like kinetics
## - Buoyancy-driven velocity field
## - Semi-Lagrangian advection + thermal diffusion
## - Fire extinguishing via cooling, oxygen starvation, fuel depletion

# --- Grid dimensions ---
var size_x: int
var size_y: int
var size_z: int
var cell_size: float  # World units per cell

# --- Species fields (flattened 3D arrays) ---
var temperature: PackedFloat32Array   # Kelvin
var fuel: PackedFloat32Array          # Normalized [0, 1]
var oxygen: PackedFloat32Array        # Normalized [0, 1]
var smoke: PackedFloat32Array         # Smoke/soot density [0, 1]

# --- Velocity field (staggered MAC grid simplified to cell-centered) ---
var velocity_x: PackedFloat32Array
var velocity_y: PackedFloat32Array
var velocity_z: PackedFloat32Array

# --- Scratch buffers for advection ---
var _temp_scalar: PackedFloat32Array
var _temp_vx: PackedFloat32Array      # Scratch for velocity_x self-advection
var _temp_vy: PackedFloat32Array      # Scratch for velocity_y self-advection
var _temp_vz: PackedFloat32Array      # Scratch for velocity_z self-advection
var _temp_t: PackedFloat32Array       # Scratch for temperature advection
var _temp_f: PackedFloat32Array       # Scratch for fuel advection
var _temp_o: PackedFloat32Array       # Scratch for oxygen advection
var _pressure: PackedFloat32Array     # Pressure field for projection
var _divergence: PackedFloat32Array   # Velocity divergence

# --- Simulation parameters ---

## Combustion
var ambient_temperature: float = 293.0   # ~20°C in Kelvin
var ignition_temperature: float = 500.0  # Min temp for combustion to start
var max_temperature: float = 1800.0      # Peak flame temperature
var stoichiometric_ratio: float = 1.0    # O₂ units consumed per fuel unit
var heat_release: float = 2000.0         # Temperature increase per unit fuel burned
var reaction_rate: float = 4.0           # Base reaction speed multiplier
var activation_energy: float = 0.5       # Arrhenius activation factor (used in exp(-Ea*Tign/T))

## Transport
var buoyancy_strength: float = 5.0       # Upward force from heat
var vorticity_epsilon: float = 2.0       # Vorticity confinement strength (ε in Fire-X Eq. 2)
var cooling_rate: float = 0.3            # Convective cooling rate (Newton's law)
var radiative_coeff: float = 0.0003      # Stefan-Boltzmann radiative cooling coeff (T⁴ is very powerful)
var thermal_diffusion: float = 0.15      # Heat spreading rate
var smoke_diffusion: float = 0.08        # Smoke spreading rate
var oxygen_diffusion: float = 0.1        # Oxygen replenishment diffusion
var velocity_diffusion: float = 0.05     # Velocity viscous diffusion (ν)
var velocity_damping: float = 0.985       # Velocity decay per step (gentle — buoyancy needs to persist)

## Environment
var wind: Vector3 = Vector3.ZERO         # External wind force
var oxygen_replenish_rate: float = 0.4   # Rate O₂ flows back from boundaries
var fuel_evaporation_rate: float = 0.0   # Solid fuel → gas phase rate

## Pressure projection
const PRESSURE_ITERATIONS := 12          # Jacobi iterations for pressure solve (warm-started)

# --- Output data for rendering (updated each step) ---
var max_reaction_rate_observed: float = 0.0
var total_heat: float = 0.0
var max_temp_observed: float = 0.0
var reaction_display: PackedFloat32Array  # Per-cell smoothed reaction intensity [0,1]


func _init(sx: int = 12, sy: int = 18, sz: int = 12, cs: float = 0.5) -> void:
	size_x = sx
	size_y = sy
	size_z = sz
	cell_size = cs
	
	var total := sx * sy * sz
	
	temperature = PackedFloat32Array()
	temperature.resize(total)
	fuel = PackedFloat32Array()
	fuel.resize(total)
	oxygen = PackedFloat32Array()
	oxygen.resize(total)
	smoke = PackedFloat32Array()
	smoke.resize(total)
	
	velocity_x = PackedFloat32Array()
	velocity_x.resize(total)
	velocity_y = PackedFloat32Array()
	velocity_y.resize(total)
	velocity_z = PackedFloat32Array()
	velocity_z.resize(total)
	
	_temp_scalar = PackedFloat32Array()
	_temp_scalar.resize(total)
	_temp_vx = PackedFloat32Array()
	_temp_vx.resize(total)
	_temp_vy = PackedFloat32Array()
	_temp_vy.resize(total)
	_temp_vz = PackedFloat32Array()
	_temp_vz.resize(total)
	_temp_t = PackedFloat32Array()
	_temp_t.resize(total)
	_temp_f = PackedFloat32Array()
	_temp_f.resize(total)
	_temp_o = PackedFloat32Array()
	_temp_o.resize(total)
	_pressure = PackedFloat32Array()
	_pressure.resize(total)
	_divergence = PackedFloat32Array()
	_divergence.resize(total)
	reaction_display = PackedFloat32Array()
	reaction_display.resize(total)
	
	# Initialize with ambient conditions
	for i in total:
		temperature[i] = ambient_temperature
		oxygen[i] = 1.0  # Full oxygen everywhere
		fuel[i] = 0.0
		smoke[i] = 0.0


## Convert 3D index to flat array index
func idx(x: int, y: int, z: int) -> int:
	return x + y * size_x + z * size_x * size_y


## Check if coordinates are within grid bounds
func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < size_x and y >= 0 and y < size_y and z >= 0 and z < size_z


## Convert world position to grid coordinates
func world_to_grid(world_pos: Vector3) -> Vector3i:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size
	return Vector3i(
		clampi(int(local.x), 0, size_x - 1),
		clampi(int(local.y), 0, size_y - 1),
		clampi(int(local.z), 0, size_z - 1)
	)


## Convert grid coordinates to world position (center of cell)
func grid_to_world(gx: int, gy: int, gz: int) -> Vector3:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	return Vector3(
		(gx + 0.5) * cell_size - offset.x,
		(gy + 0.5) * cell_size,
		(gz + 0.5) * cell_size - offset.z
	)


# =========================================================================
#  MAIN SIMULATION STEP
# =========================================================================

## Advance simulation by delta seconds
func step(delta: float) -> void:
	var dt := minf(delta, 0.05)  # Clamp timestep for stability
	
	# 1. Combustion reaction (stoichiometric)
	_step_combustion(dt)

	# 2. Forces: Boussinesq buoyancy + wind boundary + damping
	_step_forces(dt)

	# 3. Vorticity confinement — re-inject sub-grid turbulence
	_step_vorticity_confinement(dt)

	# 4. Advect ALL fields including velocity (semi-Lagrangian)
	_step_advection(dt)

	# 5. Diffusion (temperature, smoke, oxygen, AND velocity)
	_step_diffusion(dt)

	# 6. Pressure projection — enforce ∇·u = 0 (LAST velocity op,
	#    so the rendered/advected field is divergence-free)
	_step_projection()

	# 7. Velocity boundary conditions (solid ground)
	_apply_velocity_boundaries()

	# 8. Cooling: convective (Newton) + radiative (T⁴) + clamp
	_step_cooling(dt)

	# 9. Oxygen replenishment from boundaries
	_step_oxygen_replenishment(dt)


# =========================================================================
#  COMBUSTION — Heart of Fire-X
# =========================================================================

## Stoichiometry-based combustion reaction
## fuel + s * O₂ → products + Q (heat)
## Reaction rate follows Arrhenius kinetics: rate = k * fuel * oxygen
## where k = reaction_rate * exp(-activation_energy / T_normalized)
func _step_combustion(dt: float) -> void:
	# Cache member scalars as locals (avoids repeated hash lookups)
	var ign_t := ignition_temperature
	var rr := reaction_rate
	var ae := activation_energy
	var sr := stoichiometric_ratio
	var hr := heat_release
	var max_t := max_temperature
	var total := temperature.size()
	var max_rr := 0.0
	var t_heat := 0.0
	
	for i in total:
		reaction_display[i] *= 0.85
		var T := temperature[i]
		var f := fuel[i]
		var o := oxygen[i]

		if T < ign_t or f <= 0.001 or o <= 0.001:
			continue
		
		# True Arrhenius: k = A · exp(-Ea · Tign / T)
		# Goes to 0 at low T, approaches rr at high T (correct positive feedback)
		var k := rr * exp(-ae * ign_t / T)
		
		# Reaction limited by scarcer reactant (stoichiometry)
		var rate := k * minf(f, o / sr) * dt
		rate = clampf(rate, 0.0, f)
		
		var oxygen_consumed := rate * sr
		if oxygen_consumed > o:
			oxygen_consumed = o
			rate = oxygen_consumed / sr
		
		fuel[i] = f - rate
		oxygen[i] = o - oxygen_consumed
		# Incomplete combustion (Fire-X Eq. 5/6): φ = available O₂ vs stoichiometric
		# need. Starved cells burn cooler and sootier; well-fed flame burns clean/hot.
		var phi := clampf(o / (f * sr + 1e-5), 0.0, 1.0)
		# Cap temperature per step to prevent thermal overshoot
		temperature[i] = minf(T + rate * hr * lerpf(0.55, 1.0, phi), max_t)
		smoke[i] = minf(smoke[i] + rate * lerpf(1.4, 0.2, phi), 1.0)
		reaction_display[i] = maxf(clampf(rate / dt * 3.0, 0.0, 1.0), reaction_display[i])

		if rate > max_rr:
			max_rr = rate
		t_heat += rate * hr
	
	max_reaction_rate_observed = max_rr
	total_heat = t_heat


# =========================================================================
#  FORCES — Buoyancy + Wind + Damping (fused single pass)
# =========================================================================

## Apply Boussinesq buoyancy, wind (boundary condition) and damping
## Fire-X Eq. 1: f_buoy = -g(1 - T_amb/T) — purely vertical; lateral
## entrainment emerges from the pressure projection, not an explicit force
func _step_forces(dt: float) -> void:
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var amb_t := ambient_temperature
	var bs := buoyancy_strength
	var d := velocity_damping
	var has_wind := wind.length_squared() >= 0.001
	var total := temperature.size()

	# --- Buoyancy + damping + velocity clamp (all cells) ---
	for i in total:
		var T := temperature[i]
		if T > amb_t + 1.0:
			velocity_y[i] += bs * (1.0 - amb_t / T) * dt
		# Damping (viscous drag) + magnitude clamp (stability guard)
		velocity_x[i] = clampf(velocity_x[i] * d, -10.0, 10.0)
		velocity_y[i] = clampf(velocity_y[i] * d, -10.0, 10.0)
		velocity_z[i] = clampf(velocity_z[i] * d, -10.0, 10.0)

	# --- Wind as boundary condition (set velocity at inflow faces) ---
	# Boundary cells receive wind directly — interior gets it via advection
	if has_wind:
		var wx := wind.x
		var wz := wind.z
		# X-faces: x=0 (wx>0 inflow) or x=sx-1 (wx<0 inflow)
		for z_b in sz:
			var zsxy := z_b * sxy
			for y_b in sy:
				var ysx := y_b * sx
				if wx > 0.0:
					velocity_x[ysx + zsxy] = wx
				elif wx < 0.0:
					velocity_x[(sx - 1) + ysx + zsxy] = wx
		# Z-faces: z=0 (wz>0 inflow) or z=sz-1 (wz<0 inflow)
		for y_b in sy:
			var ysx := y_b * sx
			for x_b in sx:
				if wz > 0.0:
					velocity_z[x_b + ysx] = wz  # z=0 face
				elif wz < 0.0:
					velocity_z[x_b + ysx + (sz - 1) * sxy] = wz  # z=sz-1 face


# =========================================================================
#  VORTICITY CONFINEMENT — Fire-X Eq. 2/3
# =========================================================================

## Re-inject small-scale rotational motion smoothed away by the coarse grid.
## ω = ∇×u, N = ∇|ω| / ‖∇|ω|‖, f = ε·h·(N × ω)
func _step_vorticity_confinement(dt: float) -> void:
	if vorticity_epsilon <= 0.0:
		return
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var inv_2h := 0.5 / cell_size

	# Scratch buffers are dead outside advection — reuse for ω and |ω|
	_temp_vx.fill(0.0)
	_temp_vy.fill(0.0)
	_temp_vz.fill(0.0)
	_temp_scalar.fill(0.0)

	# --- Pass 1: curl ω = ∇×u (interior, central differences) ---
	for z in range(1, sz - 1):
		var zsxy := z * sxy
		for y in range(1, sy - 1):
			var base := y * sx + zsxy
			for x in range(1, sx - 1):
				var i := x + base
				var wx := (velocity_z[i + sx] - velocity_z[i - sx] - velocity_y[i + sxy] + velocity_y[i - sxy]) * inv_2h
				var wy := (velocity_x[i + sxy] - velocity_x[i - sxy] - velocity_z[i + 1] + velocity_z[i - 1]) * inv_2h
				var wz := (velocity_y[i + 1] - velocity_y[i - 1] - velocity_x[i + sx] + velocity_x[i - sx]) * inv_2h
				_temp_vx[i] = wx
				_temp_vy[i] = wy
				_temp_vz[i] = wz
				_temp_scalar[i] = sqrt(wx * wx + wy * wy + wz * wz)

	# --- Pass 2: f = ε·h·(N × ω) with N = normalized ∇|ω| ---
	var eh := vorticity_epsilon * cell_size
	for z in range(1, sz - 1):
		var zsxy := z * sxy
		for y in range(1, sy - 1):
			var base := y * sx + zsxy
			for x in range(1, sx - 1):
				var i := x + base
				var gx := (_temp_scalar[i + 1] - _temp_scalar[i - 1]) * inv_2h
				var gy := (_temp_scalar[i + sx] - _temp_scalar[i - sx]) * inv_2h
				var gz := (_temp_scalar[i + sxy] - _temp_scalar[i - sxy]) * inv_2h
				var g_mag := sqrt(gx * gx + gy * gy + gz * gz) + 1e-5
				gx /= g_mag
				gy /= g_mag
				gz /= g_mag
				var fx := eh * (gy * _temp_vz[i] - gz * _temp_vy[i])
				var fy := eh * (gz * _temp_vx[i] - gx * _temp_vz[i])
				var fz := eh * (gx * _temp_vy[i] - gy * _temp_vx[i])
				# Force clamp — blowup guard
				var f_mag := sqrt(fx * fx + fy * fy + fz * fz)
				if f_mag > 20.0:
					var s := 20.0 / f_mag
					fx *= s
					fy *= s
					fz *= s
				velocity_x[i] += fx * dt
				velocity_y[i] += fy * dt
				velocity_z[i] += fz * dt


# =========================================================================
#  VELOCITY BOUNDARIES
# =========================================================================

## Solid floor: no flow through the ground plane (sides/top stay open)
func _apply_velocity_boundaries() -> void:
	var sx := size_x
	var sxy := sx * size_y
	for z in size_z:
		var zsxy := z * sxy
		for x in sx:
			velocity_y[x + zsxy] = 0.0


# =========================================================================
#  PRESSURE PROJECTION — ∇·u⃗ = 0 (Incompressibility)
# =========================================================================

## Jacobi pressure solve to enforce divergence-free velocity field.
## Fire-X: Poisson equation ∇²p = ∇·u⃗, then u⃗ -= ∇p
## Warm-started from last step's pressure (quasi-steady plume ≈ 2× iterations).
## Ground: Neumann BC (∂p/∂y = 0 at solid floor); sides/top open (Dirichlet 0).
func _step_projection() -> void:
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var h := cell_size
	var inv_2h := 0.5 / h
	var inv_h2 := 1.0 / (h * h)
	
	# --- Step 1: Compute divergence of velocity field ---
	for z in range(1, sz - 1):
		var zsxy := z * sxy
		for y in range(1, sy - 1):
			var base := y * sx + zsxy
			for x in range(1, sx - 1):
				var i := x + base
				# Central differences: ∂u/∂x + ∂v/∂y + ∂w/∂z
				var div := (velocity_x[i + 1] - velocity_x[i - 1]) * inv_2h
				div += (velocity_y[i + sx] - velocity_y[i - sx]) * inv_2h
				div += (velocity_z[i + sxy] - velocity_z[i - sxy]) * inv_2h
				_divergence[i] = div
	
	# --- Step 2: Jacobi iteration to solve ∇²p = div ---
	# Poisson: p(i) = (sum_neighbors - h² * div(i)) / 6
	# Pressure NOT cleared: warm start from previous step's solution
	var inv6 := 1.0 / 6.0
	for _iter in PRESSURE_ITERATIONS:
		for z in range(1, sz - 1):
			var zsxy := z * sxy
			for y in range(1, sy - 1):
				var base := y * sx + zsxy
				for x in range(1, sx - 1):
					var i := x + base
					var neighbors := _pressure[i - 1] + _pressure[i + 1] \
						+ _pressure[i - sx] + _pressure[i + sx] \
						+ _pressure[i - sxy] + _pressure[i + sxy]
					_pressure[i] = (neighbors - h * h * _divergence[i]) * inv6
		# Neumann BC at solid floor: mirror y=1 pressure onto y=0
		for z_b in sz:
			var zb := z_b * sxy
			for x_b in sx:
				_pressure[x_b + zb] = _pressure[x_b + sx + zb]

	# --- Step 3: Subtract pressure gradient from velocity ---
	for z in range(1, sz - 1):
		var zsxy := z * sxy
		for y in range(1, sy - 1):
			var base := y * sx + zsxy
			for x in range(1, sx - 1):
				var i := x + base
				velocity_x[i] -= (_pressure[i + 1] - _pressure[i - 1]) * inv_2h
				velocity_y[i] -= (_pressure[i + sx] - _pressure[i - sx]) * inv_2h
				velocity_z[i] -= (_pressure[i + sxy] - _pressure[i - sxy]) * inv_2h


# =========================================================================
#  SEMI-LAGRANGIAN ADVECTION
# =========================================================================

## Advect a scalar field using the velocity field (semi-Lagrangian method)
## For each cell, trace back along velocity to find source value
## Trilinear interpolation inlined for performance (~1.2M fewer function calls)
## Advect ALL fields (velocity ×3 + temperature/fuel/oxygen/smoke) in ONE fused
## pass: backtrace position, corner indices and trilinear weights are computed
## once per cell and shared by the 7 fields (was 7 separate full-grid passes).
## Fire-X: (u·∇)u self-advection term creates vortices, turbulent plume structure
func _step_advection(dt: float) -> void:
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var dt_cs := dt / cell_size
	var fsx1 := float(sx - 1)
	var fsy1 := float(sy - 1)
	var fsz1 := float(sz - 1)
	var sx1 := sx - 1
	var sy1 := sy - 1
	var sz1 := sz - 1
	# Cache arrays as locals (packed arrays are references — avoids member lookup)
	var vx := velocity_x
	var vy := velocity_y
	var vz := velocity_z
	var tf := temperature
	var ff := fuel
	var of := oxygen
	var sf := smoke
	var out_vx := _temp_vx
	var out_vy := _temp_vy
	var out_vz := _temp_vz
	var out_t := _temp_t
	var out_f := _temp_f
	var out_o := _temp_o
	var out_s := _temp_scalar

	var i := 0
	for z in sz:
		for y in sy:
			for x in sx:
				var vxi := vx[i]
				var vyi := vy[i]
				var vzi := vz[i]

				# Still cell: nothing moves here — plain copy (most of the grid is calm air)
				if absf(vxi) + absf(vyi) + absf(vzi) < 0.001:
					out_vx[i] = vxi
					out_vy[i] = vyi
					out_vz[i] = vzi
					out_t[i] = tf[i]
					out_f[i] = ff[i]
					out_o[i] = of[i]
					out_s[i] = sf[i]
					i += 1
					continue

				# Trace back along velocity, clamp to grid bounds
				var src_xf := clampf(float(x) - vxi * dt_cs, 0.0, fsx1)
				var src_yf := clampf(float(y) - vyi * dt_cs, 0.0, fsy1)
				var src_zf := clampf(float(z) - vzi * dt_cs, 0.0, fsz1)

				var x0 := int(src_xf)
				var y0 := int(src_yf)
				var z0 := int(src_zf)
				var x1 := mini(x0 + 1, sx1)
				var y1 := mini(y0 + 1, sy1)
				var z1 := mini(z0 + 1, sz1)

				# Trilinear corner indices + weights, shared by all 7 fields
				var wx1 := src_xf - float(x0)
				var wy1 := src_yf - float(y0)
				var wz1 := src_zf - float(z0)
				var wx0 := 1.0 - wx1
				var wy0 := 1.0 - wy1
				var wz0 := 1.0 - wz1

				var y0sx := y0 * sx
				var y1sx := y1 * sx
				var z0sxy := z0 * sxy
				var z1sxy := z1 * sxy
				var i000 := x0 + y0sx + z0sxy
				var i100 := x1 + y0sx + z0sxy
				var i010 := x0 + y1sx + z0sxy
				var i110 := x1 + y1sx + z0sxy
				var i001 := x0 + y0sx + z1sxy
				var i101 := x1 + y0sx + z1sxy
				var i011 := x0 + y1sx + z1sxy
				var i111 := x1 + y1sx + z1sxy

				var wy0z0 := wy0 * wz0
				var wy1z0 := wy1 * wz0
				var wy0z1 := wy0 * wz1
				var wy1z1 := wy1 * wz1
				var w000 := wx0 * wy0z0
				var w100 := wx1 * wy0z0
				var w010 := wx0 * wy1z0
				var w110 := wx1 * wy1z0
				var w001 := wx0 * wy0z1
				var w101 := wx1 * wy0z1
				var w011 := wx0 * wy1z1
				var w111 := wx1 * wy1z1

				out_vx[i] = vx[i000] * w000 + vx[i100] * w100 + vx[i010] * w010 + vx[i110] * w110 + vx[i001] * w001 + vx[i101] * w101 + vx[i011] * w011 + vx[i111] * w111
				out_vy[i] = vy[i000] * w000 + vy[i100] * w100 + vy[i010] * w010 + vy[i110] * w110 + vy[i001] * w001 + vy[i101] * w101 + vy[i011] * w011 + vy[i111] * w111
				out_vz[i] = vz[i000] * w000 + vz[i100] * w100 + vz[i010] * w010 + vz[i110] * w110 + vz[i001] * w001 + vz[i101] * w101 + vz[i011] * w011 + vz[i111] * w111
				out_t[i] = tf[i000] * w000 + tf[i100] * w100 + tf[i010] * w010 + tf[i110] * w110 + tf[i001] * w001 + tf[i101] * w101 + tf[i011] * w011 + tf[i111] * w111
				out_f[i] = ff[i000] * w000 + ff[i100] * w100 + ff[i010] * w010 + ff[i110] * w110 + ff[i001] * w001 + ff[i101] * w101 + ff[i011] * w011 + ff[i111] * w111
				out_o[i] = of[i000] * w000 + of[i100] * w100 + of[i010] * w010 + of[i110] * w110 + of[i001] * w001 + of[i101] * w101 + of[i011] * w011 + of[i111] * w111
				out_s[i] = sf[i000] * w000 + sf[i100] * w100 + sf[i010] * w010 + sf[i110] * w110 + sf[i001] * w001 + sf[i101] * w101 + sf[i011] * w011 + sf[i111] * w111
				i += 1

	# Swap scratch buffers in as the live fields
	var swap := velocity_x
	velocity_x = _temp_vx
	_temp_vx = swap
	swap = velocity_y
	velocity_y = _temp_vy
	_temp_vy = swap
	swap = velocity_z
	velocity_z = _temp_vz
	_temp_vz = swap
	swap = temperature
	temperature = _temp_t
	_temp_t = swap
	swap = fuel
	fuel = _temp_f
	_temp_f = swap
	swap = oxygen
	oxygen = _temp_o
	_temp_o = swap
	swap = smoke
	smoke = _temp_scalar
	_temp_scalar = swap


## Trilinear interpolation of a scalar field
func _sample_trilinear(field: PackedFloat32Array, fx: float, fy: float, fz: float) -> float:
	# Clamp to grid bounds
	fx = clampf(fx, 0.0, float(size_x - 1))
	fy = clampf(fy, 0.0, float(size_y - 1))
	fz = clampf(fz, 0.0, float(size_z - 1))
	
	var x0 := int(fx)
	var y0 := int(fy)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, size_x - 1)
	var y1 := mini(y0 + 1, size_y - 1)
	var z1 := mini(z0 + 1, size_z - 1)
	
	var sx := fx - float(x0)
	var sy := fy - float(y0)
	var sz := fz - float(z0)
	
	# 8 corner values
	var c000 := field[idx(x0, y0, z0)]
	var c100 := field[idx(x1, y0, z0)]
	var c010 := field[idx(x0, y1, z0)]
	var c110 := field[idx(x1, y1, z0)]
	var c001 := field[idx(x0, y0, z1)]
	var c101 := field[idx(x1, y0, z1)]
	var c011 := field[idx(x0, y1, z1)]
	var c111 := field[idx(x1, y1, z1)]
	
	# Interpolate along x
	var c00 := lerpf(c000, c100, sx)
	var c10 := lerpf(c010, c110, sx)
	var c01 := lerpf(c001, c101, sx)
	var c11 := lerpf(c011, c111, sx)
	
	# Interpolate along y
	var c0 := lerpf(c00, c10, sy)
	var c1 := lerpf(c01, c11, sy)
	
	# Interpolate along z
	return lerpf(c0, c1, sz)


# =========================================================================
#  DIFFUSION (Jacobi iteration — all 3 fields fused in one pass)
# =========================================================================

## Apply diffusion to temperature, smoke, oxygen AND velocity.
## Velocity diffusion (viscosity ν∇²u) prevents sharp velocity gradients.
## 2 Jacobi iterations for better convergence.
func _step_diffusion(dt: float) -> void:
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var cs2 := cell_size * cell_size
	var dt_cs2 := dt / cs2
	
	var a_t := thermal_diffusion * dt_cs2
	var a_s := smoke_diffusion * dt_cs2
	var a_o := oxygen_diffusion * dt_cs2
	var a_v := velocity_diffusion * dt_cs2
	var inv_t := 1.0 / (1.0 + 6.0 * a_t)
	var inv_s := 1.0 / (1.0 + 6.0 * a_s)
	var inv_o := 1.0 / (1.0 + 6.0 * a_o)
	var inv_v := 1.0 / (1.0 + 6.0 * a_v)
	
	for _iter in 1:
		for z in range(1, sz - 1):
			var zsxy := z * sxy
			for y in range(1, sy - 1):
				var base := y * sx + zsxy
				for x in range(1, sx - 1):
					var i := x + base
					var im1 := i - 1
					var ip1 := i + 1
					var imsx := i - sx
					var ipsx := i + sx
					var imsxy := i - sxy
					var ipsxy := i + sxy
					
					# Temperature
					var n_t := temperature[im1] + temperature[ip1] + temperature[imsx] + temperature[ipsx] + temperature[imsxy] + temperature[ipsxy]
					temperature[i] = (temperature[i] + a_t * n_t) * inv_t
					
					# Smoke
					var n_s := smoke[im1] + smoke[ip1] + smoke[imsx] + smoke[ipsx] + smoke[imsxy] + smoke[ipsxy]
					smoke[i] = (smoke[i] + a_s * n_s) * inv_s
					
					# Oxygen
					var n_o := oxygen[im1] + oxygen[ip1] + oxygen[imsx] + oxygen[ipsx] + oxygen[imsxy] + oxygen[ipsxy]
					oxygen[i] = (oxygen[i] + a_o * n_o) * inv_o
					
					# Velocity X (viscosity)
					var nvx := velocity_x[im1] + velocity_x[ip1] + velocity_x[imsx] + velocity_x[ipsx] + velocity_x[imsxy] + velocity_x[ipsxy]
					velocity_x[i] = (velocity_x[i] + a_v * nvx) * inv_v
					
					# Velocity Y (viscosity)
					var nvy := velocity_y[im1] + velocity_y[ip1] + velocity_y[imsx] + velocity_y[ipsx] + velocity_y[imsxy] + velocity_y[ipsxy]
					velocity_y[i] = (velocity_y[i] + a_v * nvy) * inv_v
					
					# Velocity Z (viscosity)
					var nvz := velocity_z[im1] + velocity_z[ip1] + velocity_z[imsx] + velocity_z[ipsx] + velocity_z[imsxy] + velocity_z[ipsxy]
					velocity_z[i] = (velocity_z[i] + a_v * nvz) * inv_v


# =========================================================================
#  COOLING
# =========================================================================

## Cool cells: Newton convective + Stefan-Boltzmann radiative (T⁴)
## Also clamps all fields and dissipates smoke
func _step_cooling(dt: float) -> void:
	var amb := ambient_temperature
	var cr := cooling_rate
	var rc := radiative_coeff
	var max_t_clamp := max_temperature
	var ign_t := ignition_temperature
	var smoke_decay_rate := 0.03 * dt  # Smoke dissipation rate
	var total := temperature.size()
	var max_T := amb

	for i in total:
		var T := temperature[i]
		if T > amb:
			var excess := T - amb
			# Convective cooling: Newton's law dT/dt = -cr * (T - T_amb)
			var convective := cr * excess * dt
			# Radiative cooling: Stefan-Boltzmann ∝ T⁴
			# Normalized: (T/1000)⁴ so coefficients stay manageable
			var T_kilo := T * 0.001
			var radiative := rc * T_kilo * T_kilo * T_kilo * T_kilo * dt
			T = T - convective - radiative
			if T < amb:
				T = amb
		temperature[i] = clampf(T, amb, max_t_clamp)
		if temperature[i] > max_T:
			max_T = temperature[i]
		fuel[i] = clampf(fuel[i], 0.0, 1.0)
		oxygen[i] = clampf(oxygen[i], 0.0, 1.0)
		# Smoke only dissipates in cold cells — hot smoke persists (realistic)
		if temperature[i] < ign_t:
			smoke[i] = clampf(smoke[i] - smoke_decay_rate, 0.0, 1.0)
		else:
			smoke[i] = clampf(smoke[i], 0.0, 1.0)

	max_temp_observed = max_T


# =========================================================================
#  OXYGEN REPLENISHMENT
# =========================================================================

## Boundaries replenish oxygen (simulates fresh air)
func _step_oxygen_replenishment(dt: float) -> void:
	var replenish := oxygen_replenish_rate * dt
	var sx := size_x
	var sy := size_y
	var sz := size_z
	var sxy := sx * sy
	var rep05 := replenish * 0.5
	var rep03 := replenish * 0.3
	var top_ysx := (sy - 1) * sx
	var back_zsxy := (sz - 1) * sxy
	var right_x := sx - 1
	
	# Bottom and top faces
	for z in sz:
		var zsxy := z * sxy
		for x in sx:
			var i_bot := x + zsxy
			oxygen[i_bot] = minf(oxygen[i_bot] + replenish, 1.0)
			var i_top := x + top_ysx + zsxy
			oxygen[i_top] = minf(oxygen[i_top] + rep05, 1.0)
	
	# Front, back, left, right faces
	for y in sy:
		var ysx := y * sx
		for x in sx:
			var i_front := x + ysx
			oxygen[i_front] = minf(oxygen[i_front] + rep03, 1.0)
			var i_back := x + ysx + back_zsxy
			oxygen[i_back] = minf(oxygen[i_back] + rep03, 1.0)
		for z in sz:
			var zsxy := z * sxy
			var i_left := ysx + zsxy
			oxygen[i_left] = minf(oxygen[i_left] + rep03, 1.0)
			var i_right := right_x + ysx + zsxy
			oxygen[i_right] = minf(oxygen[i_right] + rep03, 1.0)


# =========================================================================
#  INTERACTION API
# =========================================================================

## Ignite: place fuel and heat at a world position
func ignite_at(world_pos: Vector3, radius: float = 1.0, fuel_amount: float = 0.8) -> void:
	var center := world_to_grid(world_pos)
	var r_cells := ceili(radius / cell_size)
	
	for dz in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			for dx in range(-r_cells, r_cells + 1):
				var gx := center.x + dx
				var gy := center.y + dy
				var gz := center.z + dz
				if not in_bounds(gx, gy, gz):
					continue
				
				var dist := Vector3(dx, dy, dz).length() * cell_size
				if dist > radius:
					continue
				
				var falloff := 1.0 - (dist / radius)
				var i := idx(gx, gy, gz)
				fuel[i] = minf(fuel[i] + fuel_amount * falloff, 1.0)
				temperature[i] = maxf(temperature[i], ignition_temperature + 200.0 * falloff)


## Add fuel source (like a burner or fuel spill)
func add_fuel_at(world_pos: Vector3, radius: float = 0.5, amount: float = 0.5) -> void:
	var center := world_to_grid(world_pos)
	var r_cells := ceili(radius / cell_size)
	
	for dz in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			for dx in range(-r_cells, r_cells + 1):
				var gx := center.x + dx
				var gy := center.y + dy
				var gz := center.z + dz
				if not in_bounds(gx, gy, gz):
					continue
				
				var dist := Vector3(dx, dy, dz).length() * cell_size
				if dist > radius:
					continue
				
				var falloff := 1.0 - (dist / radius)
				fuel[idx(gx, gy, gz)] = minf(fuel[idx(gx, gy, gz)] + amount * falloff, 1.0)


## Apply water at a position (cooling + steam production)
## Fire-X: water quenching produces steam (smoke) proportional to temperature
func apply_water_at(world_pos: Vector3, radius: float = 1.0, intensity: float = 1.0) -> void:
	var center := world_to_grid(world_pos)
	var r_cells := ceili(radius / cell_size)
	
	for dz in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			for dx in range(-r_cells, r_cells + 1):
				var gx := center.x + dx
				var gy := center.y + dy
				var gz := center.z + dz
				if not in_bounds(gx, gy, gz):
					continue
				
				var dist := Vector3(dx, dy, dz).length() * cell_size
				if dist > radius:
					continue
				
				var falloff := (1.0 - dist / radius) * intensity
				var i := idx(gx, gy, gz)
				
				# Steam production: hot surfaces + water → massive steam/smoke
				# Fire-X §4: water quench generates smoke proportional to T excess
				var T_excess := (temperature[i] - ambient_temperature) / (max_temperature - ambient_temperature)
				if T_excess > 0.05:
					var steam := falloff * T_excess * 1.5  # Hot = more steam
					smoke[i] = minf(smoke[i] + steam, 1.0)
				
				# Water cools dramatically
				temperature[i] = maxf(temperature[i] - falloff * 500.0, ambient_temperature)
				
				# Water wets fuel (reduces but doesn't destroy it)
				fuel[i] = maxf(fuel[i] - falloff * 0.15, 0.0)
				
				# Water vapor displaces oxygen (smothering effect)
				oxygen[i] = maxf(oxygen[i] - falloff * 0.3, 0.0)
				
				# Steam pushes upward
				velocity_y[i] += falloff * 3.0


## Remove oxygen in a region (smothering, e.g., fire blanket)
func smother_at(world_pos: Vector3, radius: float = 1.5) -> void:
	var center := world_to_grid(world_pos)
	var r_cells := ceili(radius / cell_size)
	
	for dz in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			for dx in range(-r_cells, r_cells + 1):
				var gx := center.x + dx
				var gy := center.y + dy
				var gz := center.z + dz
				if not in_bounds(gx, gy, gz):
					continue
				
				var dist := Vector3(dx, dy, dz).length() * cell_size
				if dist > radius:
					continue
				
				var falloff := 1.0 - (dist / radius)
				var i := idx(gx, gy, gz)
				# Smother mainly removes oxygen (blanket), minor fuel effect
				oxygen[i] = maxf(oxygen[i] - falloff * 0.6, 0.0)
				fuel[i] = maxf(fuel[i] - falloff * 0.08, 0.0)


# =========================================================================
#  SAMPLING FOR RENDERING
# =========================================================================

## Sample temperature at world position (trilinear interpolated)
func sample_temperature(world_pos: Vector3) -> float:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size - Vector3(0.5, 0.5, 0.5)
	return _sample_trilinear(temperature, local.x, local.y, local.z)


## Sample fuel at world position
func sample_fuel(world_pos: Vector3) -> float:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size - Vector3(0.5, 0.5, 0.5)
	return _sample_trilinear(fuel, local.x, local.y, local.z)


## Sample oxygen at world position
func sample_oxygen(world_pos: Vector3) -> float:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size - Vector3(0.5, 0.5, 0.5)
	return _sample_trilinear(oxygen, local.x, local.y, local.z)


## Sample smoke at world position
func sample_smoke(world_pos: Vector3) -> float:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size - Vector3(0.5, 0.5, 0.5)
	return _sample_trilinear(smoke, local.x, local.y, local.z)


## Sample velocity at world position
func sample_velocity(world_pos: Vector3) -> Vector3:
	var offset := Vector3(size_x, 0, size_z) * cell_size * 0.5
	var local := (world_pos + offset) / cell_size - Vector3(0.5, 0.5, 0.5)
	return Vector3(
		_sample_trilinear(velocity_x, local.x, local.y, local.z),
		_sample_trilinear(velocity_y, local.x, local.y, local.z),
		_sample_trilinear(velocity_z, local.x, local.y, local.z)
	)


## Get data for a horizontal slice at given y level (for debug visualization)
func get_temperature_slice(y_level: int) -> PackedFloat32Array:
	var slice := PackedFloat32Array()
	slice.resize(size_x * size_z)
	y_level = clampi(y_level, 0, size_y - 1)
	
	for z in size_z:
		for x in size_x:
			slice[x + z * size_x] = temperature[idx(x, y_level, z)]

	return slice


## Pack grid fields into RGBA8 bytes for Texture3D upload.
## R = normalized temperature, G = smoke, B = reaction intensity, A = fuel.
## Buffer must be pre-sized to size_x * size_y * size_z * 4.
func write_volume_bytes(buf: PackedByteArray) -> void:
	var amb := ambient_temperature
	var inv_range := 255.0 / (max_temperature - amb)
	var total := temperature.size()
	var b := 0
	for i in total:
		buf[b] = int(clampf((temperature[i] - amb) * inv_range, 0.0, 255.0))
		buf[b + 1] = int(clampf(smoke[i] * 255.0, 0.0, 255.0))
		buf[b + 2] = int(clampf(reaction_display[i] * 255.0, 0.0, 255.0))
		buf[b + 3] = int(clampf(fuel[i] * 255.0, 0.0, 255.0))
		b += 4
