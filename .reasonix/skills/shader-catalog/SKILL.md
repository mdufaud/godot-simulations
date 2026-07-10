---
name: shader-catalog
description: Physics Playground shader catalog — all 14 .gdshader and 16 .comp compute shaders with technique, key parameters, uniforms, dependencies. Fire raymarching (Texture3D+Planck), ocean Gerstner (6 waves+analytic FBM+SSR+Beer+foam+SSS), PBF fluid composite (screen-space Truong 2018), 3D fractal (7 types+cosine palettes), CRPOM parallax with self-shadow, grass (wind/LOD/anisotropy), 2D fractal (10 types+supersampling), post-processing, ripples, underwater, 16-stage PBF compute pipeline. Use when working with any shader or shader parameter in this project.
---

Every shader in Physics Playground — technique, params, dependencies. 14 `.gdshader` + 16 `.comp`.

## Visual Shaders

### fire.gdshader — Volumetric Raymarching
- **Type**: spatial, unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled
- **Technique**: Front-to-back raymarch, Texture3D 16×24×16 RGBA8, AABB slab, scene depth clamp
- **Channels**: R=temperature, G=smoke/soot, B=reaction, A=fuel
- **Emission**: Planck blackbody `fire_ramp(T)` layered smoothstep 600→1800K, cubic hot-core, blue flame base
- **Smoke**: Beer-Lambert extinction + cool gray scatter
- **Noise**: 2× 3D noise — density modulation + edge erosion. Jitter: interleaved gradient.
- **Key params**: `volume_tex`, `noise_tex`, `box_size`, `emission_strength`, `flame_absorption`, `smoke_absorption`, `blue_strength`
- **Deps**: `fire_controller.gd` uploads Texture3D. `fire_simulation_grid.gd` generates grid.

### ocean.gdshader — Gerstner Wave Ocean
- **Type**: spatial, cull_disabled, diffuse_burley, specular_schlick_ggx
- **Vertex**: 6 Gerstner waves — offset + gradient + crest. Ripple heightmap fetch.
- **Fragment normals**: Base (Gerstner) + 16-FBM analytic detail (exp-sin, distance faded) + ripple gradient
- **Fresnel**: Schlick F₀=0.02
- **Refraction**: SSR UV displace, depth-check fallback
- **Beer**: deep/shallow dye, `pow(depth_blend, 2.5)`
- **Foam**: Procedural — crest threshold + ripple agitation, 3-oct noise, distance-minified
- **SSS**: `pow(dot(VIEW, sun_view),3) * crest * sss_color`
- **Underside**: TIR sim — deep color at grazing
- **Key params**: `gerstner_waves[6]`, `wave_time`, `wave_height`, `choppiness`, `ripple_texture`, `water_area`, `foam_amount`, `sss_strength`, `sun_direction`
- **Deps**: `water_controller.gd` pushes params. `water_buoyancy.gd` mirrors math for physics.

### fluid_composite.gdshader — PBF Screen-Space Surface
- **Type**: spatial quad, unshaded, cull_disabled, depth_draw_never, depth_test_disabled
- **Inputs**: `SCREEN_TEXTURE`, `DEPTH_TEXTURE`, `fluid_depth_tex` (R=floor(d), G=fract(d), B=attr), `thickness_tex`
- **Normal**: Reconstruct from filtered depth — central diff, smaller-difference pick at silhouettes
- **Water**: SSR refraction + Beer-Lambert absorp + sky Fresnel + spec highlight
- **Lava**: Blackbody emission from front temp, hot interior bleeding through crust
- **Key params**: `absorption`, `absorption_scale`, `tint_color`, `sky_color`, `sun_direction`, `refraction_strength`, `spec_power`, `mode` (0=water, 1=lava)
- **Deps**: `fluid_controller.gd` sets up all textures + mode.

### fractal_3d.gdshader — 3D Raymarched Fractals
- **Type**: spatial, world_vertex_coords, unshaded, cull_front, depth_test_disabled
- **Types**: 0=Mandelbulb, 1=Julia, 2=Mandelbox, 3=Menger, 4=Sierpinski, 5=KIFS, 6=Apollonian
- **DE**: Per-type analytic DE, inout iter + orbit trap. Sphere tracing, 500 max steps.
- **Normal**: Central-diff gradient (eps*10)
- **Shading**: Phong diffuse + Blinn-Phong spec + rim + 5-step AO
- **Colors**: 5 cosine palettes, 6 modes (Cosmic, Orbit Trap, HSV, Thermal, Fog, Iridescent)
- **Refs**: Hart 1996, White & Nylander 2009, Tomalak 2010, Knighty 2010
- **Deps**: `fractal_3d_controller.gd`. `fractal_de.gd` mirrors DE on CPU for camera collision.

### parallax.gdshader — CRPOM Parallax Mapping
- **Type**: spatial, blend_mix, depth_draw_opaque, diffuse_burley, specular_schlick_ggx
- **Technique**: Contact Refinement POM (Andrea Riccardi)
- **Pass**: Coarse steep → subdivide one step → linear interpolate
- **Self-shadow**: Tangent-space ray trace per light in `light()`
- **PBR**: D_GGX, V_Smith, F_Schlick reimplemented (custom light() disables built-in)
- **Key params**: `height_scale`, `min_layers`, `max_layers`, `self_shadow_enabled`, `shadow_strength`, `uv_scale`, `use_computed_normals`
- **Deps**: `parallax_controller.gd` manages presets + mesh.

### grass.gdshader — Grass with Wind + LOD
- **Type**: spatial, cull_disabled, ensure_correct_normals
- **Vertex**: Hash height/width, 2-axis wind (turn+bend), LOD thickening, view-space thicken, heightmap offset
- **Wind**: Noise direction + turbulence, height-dependent time offset, player crushing factor
- **Fragment**: Base→tip gradient, height AO, distance→uniform blend, fog
- **Light**: `pow(4.0, dot(N,L))/4.0` diffuse (never dark), `max(-dot(V,L),0)*sss_color` backlight SSS, ANISOTROPY=0.85
- **Key params**: `clumping_factor`, `clump_noise`, `wind_speed`, `wind_noise`, `base_color`, `tip_color`, `subsurface_scattering_color`
- **Globals**: `heightmap`, `heightmap_scale`, `player_position`
- **Deps**: `grass_controller.gd` multimesh LOD + global pushes.

### fractal.gdshader — 2D Fractal Explorer
- **Type**: canvas_item
- **Types**: Mandelbrot (cardioid early-out), Julia, Burning Ship, Newton, Tricorn, Nova, Phoenix, Cosine, Magnet 1, Spider
- **AA**: N×N supersampling (quality 1-4)
- **Colors**: Smooth iter→cosine palette, Orbit trap, HSV cyclic, Thermal lava
- **Kaleido**: N-fold rotational folding
- **Post**: Vignette + grain
- **Deps**: `fractal_controller.gd` view/zoom/type + auto-explore.

### post_process.gdshader — Fullscreen Post
- **Type**: canvas_item
- **Effects**: Chromatic aberration (radial R/B), vignette (sq dist), film grain (hash+TIME)

### underwater.gdshader — Underwater Overlay
- **Type**: canvas_item
- **Effects**: Wobbly sin refraction, blue-green tint 0.55 blend, vignette darken
- **Deps**: Toggled by `water_controller.gd` when camera below surface.

### ripple_sim.gdshader — Interactive Ripples
- **Type**: canvas_item, blend_disabled
- **Tech**: 2D wave eq, ping-pong SubViewports 256×256
- **Encode**: R=height+0.5, G=prev_height+0.5
- **Edge**: smoothstep border absorption — no reflection
- **Deps**: `water_controller.gd` ping-pong + splash sprites.

### fluid_impostor.gdshader — Particle Billboard Depth
- **Type**: spatial, unshaded, cull_disabled
- **Tech**: Instanced billboards, analytic sphere depth, packed eye depth (R=floor, G=fract, B=attr)
- **Deps**: `fluid_controller.gd` Viewport chain.

### fluid_thickness.gdshader — Thickness Accumulation
- **Type**: spatial, unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled
- **Tech**: Per-particle chord length, additive, no depth test. R=thickness, G=attr*thickness.

### fluid_depth_filter.gdshader — Narrow-Range Bilateral Filter
- **Type**: canvas_item
- **Tech**: Separable Gaussian, samples clamped into [depth ± radius], constant world-space footprint
- **Usage**: Run ×2 — direction (1,0) then (0,1)
- **Ref**: Truong et al. 2018

## Compute Pipeline — 16 `.comp` (GLSL 450)

### pbf_common.comp — Shared
- SPH: `poly6(r2) = poly6_c*(h²-r²)³`. `spiky_grad(r,rlen) = spiky_c*(h-r)²*r/rlen`.
- Grid: `cell_of(vec3)` → clamp. `cell_index(ivec3)` → flat. `clamp_domain(vec3)`.
- FOREACH_NEIGHBOR macro — 27-cell iteration via sorted_indices
- Push constants: 112 bytes — grid_origin(16), grid_dims(16), kernel(16), solver(16), scorr(16), gravity(16), misc(16)

### Stage Order
```
predict         → v+=g*dt, p_pred=p+v*dt, clamp
grid_clear      → cell_count=0, block_sums=0
grid_count      → atomicAdd cell_count, store cell→sorted
grid_scan       → local prefix sum, output block_sums
grid_scan_blocks→ scan block_sums → cell_start
grid_add_back   → add block offsets to local
grid_scatter    → write sorted_indices
── constraint loop (solver_iterations ×) ──
lambda          → FOREACH_NEIGHBOR → density, λ=-C/(Σ|∇C|²+ε)
delta           → δp=Σ(λi+λj+scorr)*spiky_grad*inv_rest
apply           → predicted+=δp, clamp
── end loop ──
finalize        → v=(predicted-current)/dt, clamp
vorticity_omega → ω=Σ(vj-vi)×∇W
vorticity_apply → apply vorticity force
viscosity       → XSPH: v+=c*Σ(vj-vi)*poly6
write_tex       → pack positions → rgba32f
```

### PBF Key Constants
- particles: 16384/32768/65536
- grid: 64³, cell_size=0.25, domain=16m
- h=0.25, spacing=0.12, epsilon=100.0, scorr_k=0.001
- Water: xsph_c=0.05, vorticity_eps=0.02
- Lava: xsph_c=0.35, vorticity_eps=0.0

## Boundaries
- Shader inventory only — full technique details in `simulation-pipelines`
- Shader syntax reference → use `godot-shader-reference`
- Not a rendering guide → use `godot-rendering-techniques`
