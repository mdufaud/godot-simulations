---
name: project-architecture
description: Physics Playground architecture — 13-demo registry, GameManager autoload, how to add a demo, reusable classes (OrbitCamera, FreeFlyCamera, SimMenu, PbfFluidSolver, NBodySolver, FireSimulationGrid), SimMenu API, camera setup, shader globals, folder structure, scene switching. Use when navigating or modifying this project.
---

Physics Playground project structure. Demo registry, GameManager, reusable classes, SimMenu API. How to add a demo.

## Project Config
- Godot 4.6, Forward Plus, Jolt Physics, D3D12/Windows
- Entry: `scenes/main_menu.tscn`
- Autoload: `GameManager` at `scripts/autoload/game_manager.gd`

## Demo Registry — `GameManager.DEMOS` (line 76-90)
```gdscript
const DEMOS: Array[Dictionary] = [
    {key = "ssr_demo",      title = "SSR Physics Demo",     icon = "🔮"},
    {key = "ocean_demo",    title = "FFT Ocean",            icon = "⚓"},
    {key = "fire_demo",     title = "Fire Simulation",      icon = "🔥"},
    {key = "nbody_demo",    title = "N-Body Galaxy",        icon = "🌌"},
    {key = "grass_demo",    title = "Grass Simulation",     icon = "🌿"},
    {key = "parallax_demo", title = "Parallax Mapping",     icon = "🪨"},
    {key = "fluid_demo",    title = "Fluid Simulation (PBF)", icon = "💧"},
    {key = "fractal_demo",  title = "2D Fractal Explorer",  icon = "🧠"},
    {key = "fractal_3d_demo", title = "3D Fractal Explorer", icon = "🧊"},
    {key = "tornado_demo",  title = "Tornado Simulation",   icon = "🌪️"},
    {key = "sand_demo",     title = "Heightfield Sand",  icon = "🏖️"},
    {key = "cloth_demo",    title = "Cloth in a Tornado",   icon = "🏳️"},
    {key = "destruction_demo", title = "Voronoi Destruction", icon = "🧱"},
]
```

## Add a Demo — 5 Steps
1. Create controller `scripts/demos/my_controller.gd`
2. Create scene `scenes/my_demo.tscn` — include `CameraPivot` (OrbitCamera) or `FreeFlyCamera`, `UI/SimMenu` node, `WorldEnvironment`
3. Add `{key, title, icon}` to `GameManager.DEMOS`
4. Add `"my_demo": "res://scenes/my_demo.tscn"` to `GameManager.SCENES`
5. Menu auto-builds button from DEMOS array

## Reusable Classes
| Class | File | Purpose |
|-------|------|---------|
| `GameManager` | `scripts/autoload/game_manager.gd` | Scene switching, settings dict, DEMOS |
| `SimMenu` | `scripts/ui/sim_menu.gd` | Scrollable panel — sliders, toggles, buttons, progress bars, color pickers |
| `OrbitCamera` | `scripts/orbit_camera.gd` | Mouse orbital cam — target, distance, pitch, yaw, zoom limits |
| `FreeFlyCamera` | `scripts/free_fly_camera.gd` | WASD fly cam — DE-based adaptive speed |
| `PbfFluidSolver` | `scripts/pbf_fluid_solver.gd` | RD compute — 65K particles, 16 stages |
| (no class_name) | `scripts/sand/heightfield_sand.gd` | RD compute — heightfield sand, repose-angle relaxation |
| `ClothSolver` | `scripts/cloth/cloth_solver.gd` | RD compute — XPBD cloth grid, no hash needed |
| `OceanSolver` | `scripts/ocean/ocean_solver.gd` | RD compute — FFT ocean, displacement/normal+foam texture arrays via Texture2DArrayRD |
| `OceanClipmap` | `scripts/ocean/ocean_clipmap.gd` | Static ArrayMesh builder — 64×64-cell levels, degenerate crack fillers, horizon skirt |
| `VoronoiFracture` | `scripts/destruction/voronoi_fracture.gd` | Bakes a box into convex Voronoi cells |
| `FireSimulationGrid` | `scripts/fire_simulation_grid.gd` | Grid combustion — 16×24×16, Arrhenius |

## SimMenu API
```gdscript
@onready var menu: SimMenu = $UI/SimMenu

menu.title = "🔥 Demo"
menu.add_label("Status: running")                             # Read-only text
menu.add_separator()                                           # Horizontal line
menu.add_section("Parameters")                                 # Section header
menu.add_slider("Label", 0.0, 10.0, 5.0, func(v): param = v)
menu.add_toggle("Toggle", false, func(on): setting = on)
menu.add_button("Action", func(): do_thing())
menu.add_progress_bar("Stat", 100.0)                           # Returns ProgressBar
menu.add_color_picker("Color", Color.WHITE, func(c): tint = c)
```

## Camera Setup
```gdscript
@onready var cam: OrbitCamera = $CameraPivot
func _ready():
    cam.target = Vector3.ZERO; cam.distance = 15.0
    cam.pitch = -25.0; cam.yaw = 45.0
    cam.min_distance = 5.0; cam.max_distance = 50.0
    cam.max_pitch = 80.0
```

## Shader Globals (`project.godot:74-84`)
```
heightmap         : sampler2D — grass terrain (set by grass_controller.gd)
heightmap_scale   : float = 5.0
player_position   : vec3    — grass crushing under player
```

## Scene Switching
```gdscript
GameManager.load_demo("ocean_demo")  # → switch
GameManager.go_to_menu()             # → main menu
GameManager.quit_game()              # → exit
```

## Settings Store
```gdscript
GameManager.get_setting("ssr_enabled")         # → value or default
GameManager.set_setting("ssr_enabled", false)   # → emits settings_changed
GameManager.settings["parallax_height"]         # → 0.08
```

## Folder Layout
```
physics-test/
├── scenes/          # .tscn + ui/sim_menu.tscn
├── scripts/         # autoload/ + demos/ + ui/
├── shaders/         # .gdshader + pbf|sand|cloth|nbody/*.comp
├── resources/       # .tres materials, themes, .obj models
├── textures/        # g_a.png, g_n.png
├── docs/            # fire_simulation.md (French, Fire-X deep dive)
├── bin/             # .exe, .x86_64, .apk, .pck
└── android/         # Gradle, Kotlin tests
```

## 13 Demo Quick Ref
| Key | Script | Technique |
|-----|--------|-----------|
| `ssr_demo` | `ssr_controller.gd` | SSR + Jolt rigid bodies |
| `ocean_demo` | `ocean_controller.gd` | Tessendorf FFT: JONSWAP/TMA spectrum, Stockham IFFT, 3 cascades (tiles 1013/127/17 m), Jacobian foam, clipmap + Poly Haven rocks |
| `fire_demo` | `fire_controller.gd` | Grid CPU + Texture3D raymarch |
| `nbody_demo` | `nbody_controller.gd` | GPU N-body Verlet + additive sprites |
| `grass_demo` | `grass_controller.gd` | Multimesh LOD + wind |
| `parallax_demo` | `parallax_controller.gd` | CRPOM + self-shadow |
| `fluid_demo` | `fluid_controller.gd` | 65K GPU PBF + screen-space |
| `fractal_demo` | `fractal_controller.gd` | 10 fractal types + AA |
| `fractal_3d_demo` | `fractal_3d_controller.gd` | 7 fractals + raymarching |
| `tornado_demo` | `tornado_controller.gd` | Analytic wind field + raymarch + debris |
| `sand_demo` | `sand_controller.gd` | GPU heightfield sand: repose flow + dig/pour/smooth brushes |
| `cloth_demo` | `cloth_controller.gd` | GPU XPBD cloth driven by the tornado wind field |
| `destruction_demo` | `destruction_controller.gd` | Voronoi pre-fracture + Jolt sleep islands |

## Compute Solver Gotchas (verified in this repo)
- **Sand/PBF/N-body all share the grid recipe**: clear → predict+count → scan → scatter (cell-sorted
  ping-pong). Cell count is capped at 262144 by the single-workgroup block scan; `SandSolver.fit_grid()`
  grows the cell size until the domain fits.
- **Cloth needs no hash grid** — a regular mesh finds neighbours by index arithmetic.
- **`.comp` files are non-resources**: every export preset needs `include_filter="*.comp"` or the shaders
  are silently dropped from the PCK and the solver dies on export only.
- **Godot's front faces are clockwise** — procedurally built hull faces must wind against their outward
  normal or they are culled (hit while building the Voronoi wall).

## Boundaries
- Project-specific. Global Godot reference → use `godot-shader-reference`, `godot-compute-gdscript`, etc.
- Not a tutorial for each demo's internals → see `simulation-pipelines` or `shader-catalog`.
