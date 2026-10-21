#!/usr/bin/env bash
# The project's single probe launcher: runs one of the tests/probe.gd probes
# under the shared setsid/timeout/group-kill primitive on an isolated virtual
# Wayland display, and sweeps leftover godot processes after crashes.
#
#   tests/probe.sh list
#   tests/probe.sh fluid_foam
#   tests/probe.sh grass seed=1
#   tests/probe.sh fps nbody_demo medium
#   tests/probe.sh fps ocean_demo low 1920x1080 6
#   tests/probe.sh fps target=ocean_demo tier=medium size=1280x720 seconds=5
#   tests/probe.sh kill
#
# Every spawn records its pid in .godot/launched.pids; `kill` group-TERM/KILLs
# those plus any stray project test godot (never a user's open editor) and
# orphaned virtual kwins. Nuclear for this project's test processes: do not
# run it while another agent's run matters.
# If KWin fails before Godot starts, inspect its log, run `tests/probe.sh kill`
# once, and retry once. If KWin fails again, stop restarting it. For a
# headless-capable probe, run `godot --headless --path . -s tests/probe.gd --
# <name> [args]` directly. That checks logic and scene wiring only; visual
# claims still need a real capture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-probe-$$}"

source "$SCRIPT_DIR/virtual_display.sh"

# name|timeout|pass sentinel (matched against probe stdout)|summary tag (grep
# -E fragment matching the probe's own diagnostics lines)
PROBE_TABLE=(
	"nbody_numeric|180|^TEST PASS nbody_numeric$|"
	"terrain_hydro|300|^TEST PASS terrain_hydro$|TERRAIN HYDRO "
	"nbody_perf|600|^TEST PASS nbody_perf$|NBODY PERF "
	"fluid_foam|180|^TEST PASS fluid_foam$|FLUFOAM "
	"fluid_honey_fall|180|^TEST PASS fluid_honey_fall$|FLUHONEY "
	"fluid_materials|180|^TEST PASS fluid_materials$|FLUMAT "
	"fluid_pool|180|^TEST PASS fluid_pool$|FLUPOOL "
	"planet_water|240|^TEST PASS planet_water$|PLANET WATER "
	"fluid_scene_retention|120|^TEST PASS fluid_scene_retention$|FLUSCENE "
	"fluid_resize|120|^FLU3 PROBE DONE|FLU3 "
	"fluid_tier|180|^TEST PASS fluid_tier$|FLUTIER "
	"fractal_policy|300|^POLICY PROBE PASS$|POLICY "
	"fractal_zoom|300|^FR2 PROBE DONE|FR2 "
	"grass|120|^GRA3 PROBE DONE|GRA3 "
	"planet_controls|180|^TEST PASS planet_controls$|PLANET CONTROLS "
	"planet_orbits|240|^TEST PASS planet_orbits$|PLANET ORBITS "
	"planet_volcanoes|300|^TEST PASS planet_volcanoes$|PLANET VOLCANOES "
	"planet_shape|240|^TEST PASS planet_shape$|PLANET SHAPE "
	"mixopt|180|^MIXOPT PROBE DONE ok$|MIXOPT "
	"tornado_boot_look|180|^TEST PASS tornado_boot_look$|"
	"fps|120|^FPS PROBE target=|FPS PROBE "
	"foam_convergence|600|^FOAM CONVERGENCE DONE|FOAM "
	"foam_histogram|300|^HISTO DONE|HISTO "
	"ocean_freeze|120|^TEST PASS ocean_freeze$|OCEAN FREEZE "
	"river_swe|180|^TEST PASS river_swe$|RIVER SWE "
	"river_waterfall|240|^TEST PASS river_waterfall$|RIVER WATERFALL "
	"river_shutdown|90|^TEST PASS river_shutdown$|RIVER SHUTDOWN "
	"river_motion|240|^PROBE DONE river_motion|RIVER MOTION "
	"river_foam_render|60|^TEST PASS river_foam_render$|RIVER FOAM "
	"river_slope|900|^TEST PASS river_slope$|RIVER SLOPE "
	"river_domain|180|^TEST PASS river_domain$|RIVER DOMAIN "
	"river_fixtures|1200|^RIVER FIXTURES DONE|RIVER FIXTURE "
	"ocean_contracts|60|^TEST PASS ocean_contracts$|OCEAN CONTRACTS "
	"ocean_parameters|600|^TEST PASS ocean_parameters_gpu$|OCEAN PARAM "
	"ocean_swell|240|^TEST PASS ocean_swell$|OCEAN (PARAM|SWELL) "
	"ocean_extremes|240|^TEST PASS ocean_extremes$|OCEAN (PARAM|EXTREME) "
	"ocean_capture|240|^TEST PASS ocean_capture$|OCEAN CAPTURE "
	"ocean_ultra|180|^TEST PASS ocean_ultra$|OCEAN ULTRA "
	"ocean_single_wave|120|^TEST PASS ocean_single_wave$|OCEAN WAVE "
	"ocean_island_spectrum|300|^TEST PASS ocean_island_spectrum$|OCEAN ISLAND SPEC "
	"ocean_island_visual|180|^TEST PASS ocean_island_visual$|OCEAN ISLAND VISUAL "
	"ocean_seam|600|^TEST PASS ocean_seam$|OCEAN SEAM "
	"ocean_shore_dispersion|600|^TEST PASS ocean_shore_dispersion$|OCEAN DISP "
	"ocean_shore_dispersion_2d|180|^TEST PASS ocean_shore_dispersion_2d$|OCEAN DISP "
	"ocean_shore_convergence|240|^TEST PASS ocean_shore_convergence$|OCEAN DISP "
	"ocean_shore_volume|600|^TEST PASS ocean_shore_volume$|OCEAN VOL "
	"ocean_shore_foam|180|^TEST PASS ocean_shore_foam$|OCEAN FOAM "
	"ocean_boundary_phase|120|^TEST PASS ocean_boundary_phase$|OCEAN PHASE "
	"ocean_breaking_diffusion|120|^TEST PASS ocean_breaking_diffusion$|OCEAN BREAK "
	"ocean_sph_breaker|300|^TEST PASS ocean_sph_breaker$|BREAKER "
	"ocean_sph_stiffness|180|^TEST PASS ocean_sph_stiffness$|BREAKER "
	"ocean_sph_pressure_conservation|120|^TEST PASS ocean_sph_pressure_conservation$|BREAKER SPH PRESSURE CONSERVATION "
	"ocean_breaker_boot|120|^TEST PASS ocean_breaker_boot$|BREAKER "
	"ocean_apic_breaker|300|^TEST PASS ocean_apic_breaker$|BREAKER "
	"ocean_apic_rest|180|^TEST PASS ocean_apic_rest$|BREAKER "
	"ocean_apic_surface_projection|120|^TEST PASS ocean_apic_surface_projection$|BREAKER APIC SURFACE PROJECTION "
	"ocean_apic_surface_transport|120|^TEST PASS ocean_apic_surface_transport$|BREAKER APIC SURFACE TRANSPORT "
	"ocean_apic_amount_transport|180|^TEST PASS ocean_apic_amount_transport$|BREAKER APIC AMOUNT "
	"ocean_apic_cube_fraction|180|^TEST PASS ocean_apic_cube_fraction$|BREAKER APIC CUBE FRACTION "
	"ocean_apic_linear_wave|180|^TEST PASS ocean_apic_linear_wave$|BREAKER APIC LINEAR WAVE "
	"ocean_apic_geometric_flux_cache|180|^TEST PASS ocean_apic_geometric_flux_cache$|BREAKER APIC GEOMETRIC CACHE "
	"ocean_apic_amount_reconstruction|180|^TEST PASS ocean_apic_amount_reconstruction$|BREAKER APIC AMOUNT RECONSTRUCTION "
	"ocean_apic_amount_consistency|180|^TEST PASS ocean_apic_amount_consistency$|BREAKER APIC AMOUNT CONSISTENCY "
	"ocean_apic_surface_strain|120|^TEST PASS ocean_apic_surface_strain$|BREAKER APIC SURFACE STRAIN "
	"ocean_apic_surface_wall_barrier|120|^TEST PASS ocean_apic_surface_wall_barrier$|BREAKER APIC SURFACE WALL BARRIER "
	"ocean_apic_surface_boot|180|^TEST PASS ocean_apic_surface_boot$|BREAKER APIC SURFACE BOOT "
	"ocean_apic_surface_rest|180|^TEST PASS ocean_apic_surface_rest$|BREAKER SHORE REST "
	"ocean_apic_surface_breaker|180|^TEST PASS ocean_apic_surface_breaker$|BREAKER "
	"ocean_apic_surface_volume|300|^TEST PASS ocean_apic_surface_volume$|BREAKER "
	"ocean_apic_surface_timestep|360|^TEST PASS ocean_apic_surface_timestep$|BREAKER TIMESTEP "
	"ocean_apic_volume_fraction|60|^TEST PASS ocean_apic_volume_fraction$|BREAKER APIC VOLUME FRACTION "
	"ocean_apic_velocity_support|120|^TEST PASS ocean_apic_velocity_support$|BREAKER APIC VELOCITY SUPPORT "
	"ocean_apic_detached_gravity|180|^TEST PASS ocean_apic_detached_gravity$|BREAKER APIC DETACHED "
	"ocean_apic_thin_film|120|^TEST PASS ocean_apic_thin_film$|BREAKER APIC THIN FILM "
	"ocean_apic_film_current|120|^TEST PASS ocean_apic_film_current$|BREAKER APIC FILM CURRENT "
	"ocean_apic_solid_geometry|120|^TEST PASS ocean_apic_solid_geometry$|BREAKER APIC SOLID GEOMETRY "
	"ocean_apic_dry_cut_cell|120|^TEST PASS ocean_apic_dry_cut_cell$|BREAKER APIC DRY (CUT CELL|FACE TRANSPORT) "
	"ocean_breaker_seed|60|^TEST PASS ocean_breaker_seed$|BREAKER SEED "
	"ocean_apic_shore_rest|180|^TEST PASS ocean_apic_shore_rest$|BREAKER SHORE REST "
	"ocean_sph_shore_rest|180|^TEST PASS ocean_sph_shore_rest$|BREAKER SHORE REST "
	"ocean_apic_grid|360|^TEST PASS ocean_apic_grid$|BREAKER "
	"ocean_apic_dense|600|^TEST PASS ocean_apic_dense$|BREAKER "
	"ocean_apic_scatter|300|^TEST PASS ocean_apic_scatter$|BREAKER "
	"ocean_apic_transfer|180|^TEST PASS ocean_apic_transfer$|BREAKER P2G "
	"ocean_apic_timestep|360|^TEST PASS ocean_apic_timestep$|BREAKER TIMESTEP "
	"ocean_apic_wall_slip|180|^TEST PASS ocean_apic_wall_slip$|BREAKER WALL SLIP "
	"ocean_breaker_incident|60|^TEST PASS ocean_breaker_incident$|BREAKER INCIDENT CPU "
	"ocean_sph_prediction|180|^TEST PASS ocean_sph_prediction$|BREAKER SPH PREDICTION "
	"ocean_sph_density_snapshot|180|^TEST PASS ocean_sph_density_snapshot$|BREAKER SPH DENSITY SNAPSHOT "
)

usage() {
	printf 'usage: tests/probe.sh list\n'
	printf '       tests/probe.sh <name> [args...]\n'
	printf '       tests/probe.sh fps <demo> <low|medium|high|ultra> [WxH] [seconds]\n'
	printf '       tests/probe.sh fps target=... tier=... [size=...] [seconds=...]\n'
	printf '       tests/probe.sh fps target=ambient_fluid_demo tier=high size=1280x720 bodies=24\n'
	printf '       tests/probe.sh kill\n'
	printf 'names: %s\n' "$(probe_names | tr '\n' ' ')"
}

probe_names() {
	local entry
	for entry in "${PROBE_TABLE[@]}"; do
		printf '%s\n' "${entry%%|*}"
	done
}

lookup_probe() {
	local name="$1"
	local entry
	for entry in "${PROBE_TABLE[@]}"; do
		if [[ "${entry%%|*}" == "$name" ]]; then
			PROBE_TIMEOUT="${entry#*|}"
			PROBE_SENTINEL="${PROBE_TIMEOUT#*|}"
			PROBE_TIMEOUT="${PROBE_TIMEOUT%%|*}"
			PROBE_TAG="${PROBE_SENTINEL#*|}"
			PROBE_SENTINEL="${PROBE_SENTINEL%%|*}"
			return 0
		fi
	done
	return 1
}

kill_leftovers() {
	physics_test_kill_leftovers
}

PROBE_OWNS_DISPLAY=0

cleanup() {
	local status=$?
	if (( PROBE_OWNS_DISPLAY )); then
		physics_test_display_stop
	fi
	exit "$status"
}

run_probe() {
	local name="$1"
	shift
	if ! lookup_probe "$name"; then
		printf 'probe: unknown name %s\n' "$name" >&2
		usage >&2
		return 2
	fi
	local timeout_seconds="${TIMEOUT:-$PROBE_TIMEOUT}"

	mkdir -p "$LOG_DIR"
	LOG_DIR="$(cd "$LOG_DIR" && pwd)"

	# Shared lock on the import cache, same convention as the gate runners.
	mkdir -p "$PROJECT_DIR/.godot"
	exec 9>>"$PROJECT_DIR/.godot/import.lock"
	flock -s 9

	trap cleanup EXIT
	trap 'exit 130' INT TERM

	if ! physics_test_display_ready; then
		if ! physics_test_display_start "$LOG_DIR/virtual-display.log" >/dev/null; then
			printf 'probe: virtual display failed to start; see %s\n' \
				"$LOG_DIR/virtual-display.log" >&2
			exit 1
		fi
		PROBE_OWNS_DISPLAY=1
	fi

	local stdout_log="$LOG_DIR/$name.stdout.log"
	local godot_log="$LOG_DIR/$name.godot.log"
	local status=0
	local launch=("$GODOT")
	if [[ "$name" == river_shutdown ]]; then
		launch=(bash -c 'ulimit -c 0; "$@"; result=$?; if (( result == 0 )); then printf "TEST PASS river_shutdown\n"; fi; exit "$result"' -- "$GODOT")
	fi
	physics_test_run_process "$timeout_seconds" "$PROBE_SENTINEL" "$stdout_log" \
		env -u DISPLAY ${PHYSICS_TEST_X11_DISPLAY:+"DISPLAY=$PHYSICS_TEST_X11_DISPLAY"} \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"${launch[@]}" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--log-file "$godot_log" \
			-s res://tests/probe.gd -- "$name" "$@" || status=$?

	local reason=""
	if (( status != 0 )); then
		reason="$(physics_test_describe_status "$status")"
	elif grep -qE '^(SCRIPT ERROR:|ERROR:|handle_crash:)' "$stdout_log" 2>/dev/null; then
		status=1
		reason="error lines in its output"
	elif ! grep -q -- "$PROBE_SENTINEL" "$stdout_log" 2>/dev/null; then
		status=1
		reason="exited without its sentinel ($PROBE_SENTINEL)"
	fi
	if (( status != 0 )); then
		printf 'probe: %s failed: %s; logs in %s\n' "$name" "$reason" "$LOG_DIR" >&2
		grep -m 3 -A 2 'SCRIPT ERROR:' "$stdout_log" >&2 || true
		tail -n 30 "$stdout_log" >&2 || true
		exit "$status"
	fi
	local summary_pattern="^TEST (PASS|FAIL)"
	if [[ -n "$PROBE_TAG" ]]; then
		summary_pattern="^(TEST (PASS|FAIL)|$PROBE_TAG)"
	fi
	grep -E "$summary_pattern" "$stdout_log" || true
}

# fps accepts either all key=value or all positional <demo> <tier> [WxH] [s].
run_fps() {
	local has_kv=0 has_pos=0 arg
	for arg in "$@"; do
		if [[ "$arg" == *"="* ]]; then
			has_kv=1
		else
			has_pos=1
		fi
	done
	if (( has_kv && has_pos )); then
		printf 'probe: fps args must be all key=value or all positional\n' >&2
		return 2
	fi
	if (( has_kv )); then
		run_probe fps "$@"
		return
	fi
	local target="${1:?usage: tests/probe.sh fps <demo> <tier> [WxH] [seconds]}"
	local tier="${2:?usage: tests/probe.sh fps <demo> <tier> [WxH] [seconds]}"
	local size="${3:-1920x1080}"
	local seconds="${4:-5}"
	run_probe fps "target=$target" "tier=$tier" "size=$size" "seconds=$seconds"
}

case "${1:-}" in
	"")
		usage >&2
		exit 2
		;;
	list)
		probe_names
		;;
	kill)
		kill_leftovers
		;;
	fps)
		shift
		run_fps "$@"
		;;
	-*)
		usage >&2
		exit 2
		;;
	*)
		name="$1"
		shift
		run_probe "$name" "$@"
		;;
esac
