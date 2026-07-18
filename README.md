# Physics Playground

A collection of 16 real-time simulation and rendering demos built in Godot 4.6
(Forward+ renderer, Jolt physics). Most run their solver on the GPU through
`RenderingDevice` compute shaders.

## Requirements

- **Godot 4.6** — Forward+ renderer, so a Vulkan/D3D12-capable GPU is required.
  The Compatibility renderer will not work: it exposes no `RenderingDevice`.
- **Python 3** — only to fetch the rock assets (standard library only, no pip install).

## Setup

The rock models are not stored in this repository (see [Assets](#assets)). Fetch
them first, then open the project:

```bash
./tools/fetch_assets.py
godot project.godot
```

Skipping the fetch leaves `ocean_demo` without its rocks. Every other demo runs
without it.

## Demos

Launched from the main menu (`scenes/main_menu.tscn`).

| Demo | Technique |
|------|-----------|
| SSR Physics Demo | Screen-space reflections + Jolt rigid bodies |
| FFT Ocean | Tessendorf FFT — JONSWAP/TMA spectrum, Stockham IFFT, 3 cascades, Jacobian foam, clipmap mesh |
| Fire Simulation | Arrhenius combustion grid + Texture3D raymarch |
| N-Body Galaxy | GPU Verlet integration + additive point sprites |
| Grass Simulation | Multimesh LOD + wind |
| Parallax Mapping | Cone-relaxed parallax occlusion + per-light self-shadowing |
| Fluid Simulation (PBF) | 65K-particle GPU position-based fluid + screen-space surfacing |
| 2D Fractal Explorer | 10 fractal types, deep-zoom perturbation, progressive refinement |
| 3D Fractal Explorer | 7 distance-estimated fractals, sphere tracing |
| Tornado Simulation | Analytic wind field + volumetric raymarch + rigid-body debris |
| Heightfield Sand | GPU heightfield with repose-angle flow, dig/pour/smooth brushes |
| Cloth in the Wind | GPU XPBD cloth driven by the tornado wind field |
| Voronoi Destruction | Voronoi pre-fracture + Jolt sleep islands |
| Procedural Planet | GPU marching cubes over a ridged-FBM density field + raymarched Rayleigh atmosphere, with SPH fluid colliding against the live density field under radial gravity |

## Layout

```
scenes/      Demo scenes + main menu + shared UI
scripts/
  autoload/  GameManager — scene registry, settings, scene switching
  demos/     One controller per demo
  ui/        SimMenu — the in-demo settings panel
  ocean/     OceanSolver (FFT compute), OceanClipmap (mesh builder)
  cloth/ nbody/ sand/ destruction/   Per-simulation solvers
  *.gd       Shared pieces — OrbitCamera, FreeFlyCamera, PbfFluidSolver
shaders/     .gdshader (visual) and .comp (compute) sources
resources/   Meshes, materials, themes — rocks/ is fetched, not committed
tools/       Asset fetch script
```

Adding a demo means appending a `{key, title, icon}` entry to `GameManager.DEMOS`
and a path to `GameManager.SCENES`; the menu builds its buttons from that array.

## Assets

The Poly Haven rock models (`boulder_01`, `rock_face_02`,
`namaqualand_boulder_03`, `namaqualand_cliff_01`) are **CC0** and weigh ~44 MB, so
they are gitignored and downloaded on demand by `tools/fetch_assets.py` instead of
being committed. The script pulls the 2k glTF variant from the Poly Haven API,
skips files already present, and is safe to re-run.
