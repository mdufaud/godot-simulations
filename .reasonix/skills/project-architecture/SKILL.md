---
name: project-architecture
description: Physics Playground architecture — 9-demo registry, GameManager autoload, how to add a demo, reusable classes (OrbitCamera, FreeFlyCamera, SimMenu, PbfFluidSolver, FireSimulationGrid), SimMenu API, camera setup, shader globals, folder structure, scene switching. Use when navigating or modifying this project.
---

Physics Playground project structure. Demo registry, GameManager, reusable classes, SimMenu API. How to add a demo.

## Project Config
- Godot 4.6, Forward Plus, Jolt Physics, D3D12/Windows
- Entry: `scenes/main_menu.tscn`
- Autoload: `GameManager` at `scripts/autoload/game_manager.gd`

## Demo Registry — `GameManager.DEMOS` (line 72-82)
```gdscript
const DEMOS: Array[Dictionary] = [
    {key = "ssr_demo",      title = "SSR Physics Demo",     icon = "🔮"},
    {key = "water_demo",    title = "Water Simulation",     icon = "🌊"},
    {key = "fire_demo",     title = "Fire Simulation",      icon = "🔥"},
    {key = "dice_demo",     title = "Dice Throw",           icon = "🎲"},
    {key = "grass_demo",    title = "Grass Simulation",     icon = "🌿"},
    {key = "parallax_demo", title = "Parallax Mapping",     icon = "🪨"},
    {key = "fluid_demo",    title = "Fluid Simulation (PBF)", icon = "💧"},
    {key = "fractal_demo",  title = "2D Fractal Explorer",  icon = "🧠"},
    {key = "fractal_3d_demo", title = "3D Fractal Explorer", icon = "🧊"},
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
GameManager.load_demo("water_demo")  # → switch
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
├── shaders/         # .gdshader + pbf/*.comp
├── resources/       # .tres materials, themes, .obj models
├── textures/        # g_a.png, g_n.png
├── docs/            # fire_simulation.md (French, Fire-X deep dive)
├── bin/             # .exe, .x86_64, .apk, .pck
└── android/         # Gradle, Kotlin tests
```

## 9 Demo Quick Ref
| Key | Script | Technique |
|-----|--------|-----------|
| `ssr_demo` | `ssr_controller.gd` | SSR + Jolt rigid bodies |
| `water_demo` | `water_controller.gd` | Gerstner + buoyancy + ripples |
| `fire_demo` | `fire_controller.gd` | Grid CPU + Texture3D raymarch |
| `dice_demo` | `dice_controller.gd` | Jolt physics + face detection |
| `grass_demo` | `grass_controller.gd` | Multimesh LOD + wind |
| `parallax_demo` | `parallax_controller.gd` | CRPOM + self-shadow |
| `fluid_demo` | `fluid_controller.gd` | 65K GPU PBF + screen-space |
| `fractal_demo` | `fractal_controller.gd` | 10 fractal types + AA |
| `fractal_3d_demo` | `fractal_3d_controller.gd` | 7 fractals + raymarching |

## Boundaries
- Project-specific. Global Godot reference → use `godot-shader-reference`, `godot-compute-gdscript`, etc.
- Not a tutorial for each demo's internals → see `simulation-pipelines` or `shader-catalog`.
