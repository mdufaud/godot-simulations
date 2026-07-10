---
name: simulation-pipelines
description: Physics Playground simulation pipelines deep dive — PBF Fluid (16 GPU compute stages with prefix-sum grid, SPH kernels, constraint solving, screen-space rendering via Truong 2018 bilateral filter), Fire (16×24×16 grid CPU with Arrhenius combustion, buoyancy, semi-Lagrangian advection, Jacobi diffusion/pressure, worker-thread at 20Hz, Texture3D upload to raymarching shader, dynamic Planck light), Water (6 Gerstner waves with analytic FBM detail normals, ping-pong ripple sim, Jolt Archimedes buoyancy mirroring wave math). Use when modifying simulation parameters or understanding data flow.
---

Deep dive on the 3 heavy simulation systems in Physics Playground.

## 1. PBF Fluid — GPU Compute (RenderingDevice)

**Algorithm**: Position-Based Fluids (Macklin & Müller 2013)
**Scale**: 65536 particles, 64³ grid, 0.25m cell, 16m domain, 16 compute stages

### Dispatch Order (barrier after each)
```
predict → grid_clear → grid_count → grid_scan → grid_scan_blocks
→ grid_add_back → grid_clear(reuse) → grid_scatter
→ [lambda→delta→apply]×solver_iterations
→ finalize → vorticity_omega→vorticity_apply → viscosity → write_tex
```

### SPH Kernels
```glsl
// Poly6: W = (315/64πh⁹)(h²-r²)³
float poly6(float r2) { float d = h2 - r2; return poly6_c * d * d * d; }
// Spiky grad: ∇W = (-45/πh⁶)(h-r)²·r/rlen
vec3 spiky_grad(vec3 r, float rlen) { float d = h - rlen; return spiky_c * d * d * r/rlen; }
```

### Constraint Formula
```
C = ρ/ρ₀ - 1 = density * inv_rest_density - 1
λ = -C / (Σ|∇Cⱼ|² + |∇Cᵢ|² + ε)
δp = Σ (λᵢ+λⱼ+scorr) * spiky_grad(pᵢ-pⱼ) * inv_rest_density
```

### Scorr Term (anti-clustering)
```
scorr = -k * (poly6(||pᵢ-pⱼ||²) / W(Δq))ⁿ
Δq = 0.3h, n=4 → prevents particle clumping at rest
```

### Screen-Space Rendering Chain
```
1. Depth prepass  → instanced billboards, analytic sphere depth, packed eye depth
2. Thickness acc  → additive per-particle chord length, no depth test
3. Filter H       → narrow-range bilateral Gaussian, direction (1,0)
4. Filter V       → same, direction (0,1)
   Filter radius = constant world-space footprint (shrinks with distance)
   Samples clamped into [depth ± particle_radius] → sharp silhouettes
5. Composite       → reconstruct normals, Fresnel+refraction+Beer (water) or blackbody (lava)
```

### Key Tuning
| Param | Water | Lava | Effect |
|-------|-------|------|--------|
| solver_iters | 3 | 3 | Constraint iterations |
| xsph_c | 0.05 | 0.35 | Viscosity |
| vorticity_eps | 0.02 | 0.0 | Vorticity confinement |
| scorr_k | 0.001 | 0.001 | Cohesion |
| render_scale | 0.5 | 0.5 | Prepass resolution |

---

## 2. Fire Simulation — CPU Grid + Worker Thread

**Algorithm**: Fire-X (Wrede et al., SIGGRAPH Asia 2025) — multi-species combustion
**Scale**: 16×24×16 grid, 0.4m cell → 6.4×9.6×6.4m domain, 20Hz fixed timestep

### Per-Cell State
```
temperature  : float K (293 ambient → 1800 max)
fuel         : float [0,1]
oxygen       : float [0,1]
smoke        : float [0,1]
velocity_xyz : 3 × float
```

### Step Loop — 7 Stages (worker thread, capped 2 steps/frame)

**1. Combustion — Arrhenius**
```
rate = A * exp(-Ea * Tign / T)
limiting = min(fuel, O₂/s)    // s = stoichiometric ratio
fuel     -= rate * limiting * dt
oxygen   -= rate * limiting * s * dt
temp     += rate * limiting * Q * dt      // Q = heat_release
smoke    += rate * limiting * 1.5 * dt
temp      = clamp(temp, Tambient, Tmax)
```

**2. Velocity — Buoyancy + Wind + Damping**
```
buoyancy = β * (T-Tamb)² * UP
// Entrainment at base (y < 0.25): pull air inward
// Expansion at top (y > 0.70): push horizontally outward
v += (buoyancy + wind + body_force + entrainment + expansion) * dt
v *= (1 - damping*dt)
```

**3. Diffusion — Jacobi ×2**
```
For T, smoke, O₂, v_xyz:
  new[i] = (old[i] + α * Σ old[neighbors]) / (1 + 6α)
```

**4. Pressure — Jacobi ×6**
```
∇²p = ∇·v   →   p[i] = (∇·v[i] + Σ p[neighbors]) / 6
v -= ∇p     // approximate incompressibility
```

**5. Advection — Semi-Lagrangian**
```
For each scalar + velocity:
  back_pos = cell_center - v[i]*dt
  new[i] = trilinear_interpolate(field, back_pos)
```

**6. Cooling — Newton + Stefan-Boltzmann**
```
ΔT = cooling_rate * (T-Tamb) * dt           // convective
ΔT += radiative_rate * (T⁴-Tamb⁴) * dt     // radiative
// Smoke decays only when cold (T < 400K)
```

**7. O₂ Replenish** — Fresh oxygen from 6 domain faces

### Thread-Safe Interaction API
```gdscript
sim.ignite_at(pos, radius, fuel_amount)      # Set fuel + temp
sim.add_fuel_at(pos, radius, amount)         # Continuous injection
sim.apply_water_at(pos, radius, intensity)   # Cool + displace O₂
sim.smother_at(pos, radius)                  # O₂ → near-zero
```
Commands buffered when sim running → applied between batches.

### Rendering
```
FireSimulationGrid (CPU, 20Hz, worker thread)
    ↓ write_volume_bytes() → PackedByteArray RGBA8
    ↓ _update_volume_texture() → ImageTexture3D.update()
    ↓
fire.gdshader (GPU, 60+ FPS)
    ├── 48-step front-to-back raymarch
    ├── Planck blackbody + blue core
    ├── 3D noise detail + edge erosion
    └── Beer-Lambert smoke absorption
    ↓
Dynamic OmniLight3D
    energy = temp_norm*8.0, range = 8+temp_norm*14
    color: Planck mapping + 2% sinusoidal flicker
```

### Key Params (SimMenu sliders)
| Param | Default | Range |
|-------|---------|-------|
| reaction_rate | 3.0 | 0.5-10 |
| heat_release | 1500 | 100-8000 |
| stoichiometric_ratio | 3.0 | 1-8 |
| buoyancy_strength | 5.0 | 1-15 |
| vorticity_epsilon | 2.5 | 0-6 |
| cooling_rate | 0.15 | 0.02-1 |
| wind.x / wind.z | 0.0 | ±5 |

---

## 3. Water Simulation — GPU Shader + Jolt Physics

### Gerstner Waves (ocean.gdshader vertex)
```
6 waves: dir(xy), steepness, wavelength
k = 2π/λ,  speed = √(g/k)  (deep-water ω²=gk)
a = (steepness/k) * height
offset.xz += dir * a * choppiness * cos(phase)
offset.y  += a * sin(phase)
grad      += dir * k*a * cos(phase)
crest     += steepness * height * max(sin(phase),0)
```
Wave gen in `water_controller.gd`: seed=1337, wind rand, wavelength 30→7.5m geometric decay.

### Detail Normals — Analytic FBM
- 16 octaves: `exp(sin(x)-1)` profile → sharp-crested
- Rotate direction ~57° per octave, freq×1.23, amp×0.79
- Distance fade `exp(-view_dist*0.02)` → AA far-water specular

### Ripples (ripple_sim.gdshader)
- Ping-pong SubViewports 256×256, alternating per physics step
- `next = (l+r+u+d)/2 - prev`, damping=0.985
- Splash injection: additive gradient sprites on canvas
- Edge: smoothstep border absorption → no reflection

### Jolt Buoyancy (water_buoyancy.gd)
```
Mirror Gerstner math in GDScript → get_water_height(pos)
  Same k, speed, phase, amplitude as shader.
  water_level = mesh.global_position.y

Per-body (_physics_process):
  depth = water_height - (body.pos.y - half.y)
  if depth > 0:
    Archimedes: F = UP * mass * 9.8 * depth/total_h
    Drag: v *= 1 - clamp(depth/total_h*2*dt, 0, 1)
    ω *= 1 - clamp(depth/total_h*5*dt, 0, 1)
```

### Environment
- Fog tint: Color(0.07, 0.28, 0.35), density=0.06 → atmospheric
- Underwater: toggled when camera.y < water_height
  - Fullscreen ColorRect + underwater.gdshader
  - Sin wobbly refraction, blue-green tint, vignette darken
  - Fog enabled only when underwater

### Key UI Params
| Slider | Shader | Physics | Default |
|--------|--------|---------|---------|
| Wave Height | wave_height | buoyancy.wave_height | 1.0 |
| Choppiness | choppiness | buoyancy.choppiness | 1.0 |
| Wave Speed | wave_time rate | buoyancy.wave_time | 1.0 |
| Foam | foam_amount | — | 1.0 |
| SSS | sss_strength | — | 1.0 |
| Ripples | ripple_strength | — | 1.0 |

## Boundaries
- Implementation details only. Theory → `docs/fire_simulation.md` (French, Fire-X paper analysis).
- Shader params reference → use `shader-catalog`.
- Project structure → use `project-architecture`.
- PBF theory (Macklin & Müller) → read the paper, not covered here.
