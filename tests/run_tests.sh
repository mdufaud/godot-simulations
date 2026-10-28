#!/usr/bin/env bash
# Runs the value gates headless (CPU suites, no window, no GPU), then — only
# with GPU=1 — the rendering suites in an invisible virtual display (kwin
# Wayland, or Xvfb + software Vulkan on GPU-less hosts).
#
#   tests/run_tests.sh                    # CPU/value gates only (the default gate)
#   GPU=1 tests/run_tests.sh              # + ocean FFT/physics, portal views, scene cycle, fluid foam, UI smoke
#   tests/run_tests.sh ocean_fft terrain  # only these suites; GPU ones start the display
#   tests/run_tests.sh --list             # suite names and kinds
#   GODOT=/path/to/godot JOBS=4 GPU_JOBS=1 tests/run_tests.sh
#
# JOBS caps the concurrent CPU suites, GPU_JOBS the concurrent GPU suites
# (default 1 each). TIMEOUT is the default per-suite budget in seconds and
# <SUITE>_TIMEOUT (e.g. OCEAN_FFT_TIMEOUT) overrides one suite. Each result
# line carries the suite's wall time; a failure names its cause (failed
# checks, script error, timeout, crash signal or exit code) and its log.
# Exit status: 0 every selected suite passed, 1 a suite failed, 2 bad usage.
#
# GPU suites assert behaviour, not image quality: they render in an 854x480
# window (PHYSICS_TEST_RESOLUTION, empty for the project's 1280x720). On a
# software Vulkan device (lavapipe, GPU-less hosts) the window drops to 640x360
# and timeouts scale x5 (PHYSICS_TEST_TIMEOUT_SCALE); see virtual_display.sh.
# The whole GPU phase takes well over an hour there: name the suites you need.
#
# All gate runners hold a shared lock on .godot/import.lock so an import
# rebuild (tools/import.sh) cannot race a running suite's script parsing.
#
# Screenshots are evidence tools, not gates: tools/capture.sh (any demo) and
# tests/run_mixwell_capture.sh (mixwell, GPU oracle) are run by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-180}"
JOBS="${JOBS:-1}"
GPU_JOBS="${GPU_JOBS:-1}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-logs-$$}"

# name|kind|timeout|godot arguments. Kinds: cpu (headless), gpu (virtual
# display, 30 simulated fps), gpu_unpaced (virtual display, real-time clock),
# ui (tests/run_ui_smoke.sh over every registered demo). Timeout "-" means
# $TIMEOUT. Every suite prints "TEST PASS <name>" when it passes.
#
# Every Godot process renders 30 frames per simulated second, each frame
# advancing exactly 1/30 s, and at most 30 per wall second, so a gate leaves
# the machine usable. Suites wait in simulated seconds, never frame counts.
declare -a SUITES=(
	"ambient_fluid|cpu|-|-s res://tests/ambient_fluid_test.gd"
	"ambient_fluid_phase3|cpu|-|-s res://tests/ambient_fluid_phase3_test.gd"
	"ambient_fluid_phase4|cpu|-|-s res://tests/ambient_fluid_phase4_test.gd"
	"ambient_fluid_validation|cpu|-|-s res://tests/ambient_fluid_validation_test.gd"
	"ambient_fluid_preprocessor|cpu|-|-s res://tests/ambient_fluid_preprocessor_test.gd"
	"ambient_fluid_float|cpu|-|-s res://tests/ambient_fluid_float_test.gd"
	"native_kernels|cpu|-|-s res://tests/native_kernels_test.gd"
	"portal_math|cpu|-|-s res://tests/portal_math_test.gd"
	"river_field|cpu|-|-s res://tests/river_field_test.gd"
	"river_boot|cpu|-|-s res://tests/river_boot_test.gd"
	"river_waterfall_curtain|cpu|-|-s res://tests/river_waterfall_curtain_test.gd"
	"growing_corridor_state|cpu|-|-s res://tests/growing_corridor_state_test.gd"
	"apparent_scale|cpu|-|-s res://tests/apparent_scale_test.gd"
	"wrap_world_state|cpu|-|-s res://tests/wrap_world_state_test.gd"
	"holonomy_state|cpu|-|-s res://tests/holonomy_state_test.gd"
	"grab_controller|cpu|-|-s res://tests/grab_controller_test.gd"
	"fire_clock|cpu|-|-s res://tests/fire_clock_test.gd"
	"fire_vorticity|cpu|-|-s res://tests/fire_vorticity_test.gd"
	"cell_propagation|cpu|-|-s res://tests/cell_propagation_test.gd"
	"wildfire_system|cpu|-|-s res://tests/wildfire_system_test.gd"
	"fire_ssot|cpu|-|-s res://tests/fire_ssot_test.gd"
	"fire_fuels|cpu|-|-s res://tests/fire_fuels_test.gd"
	"wood_pyrolysis|cpu|-|-s res://tests/wood_pyrolysis_test.gd"
	"fire_auto_ladder|cpu|-|-s res://tests/fire_auto_ladder_test.gd"
	"fire_display_box|cpu|-|-s res://tests/fire_display_box_test.gd"
	"fire_atlas|cpu|-|-s res://tests/fire_atlas_test.gd"
	"fractal_math|cpu|-|-s res://tests/fractal_math_test.gd"
	"fractal_de|cpu|-|-s res://tests/fractal_de_test.gd"
	"mixwell|cpu|-|-s res://tests/mixwell_test.gd"
	"gpu_timing_store|cpu|-|-s res://tests/gpu_timing_store_test.gd"
	"voronoi_fracture|cpu|-|-s res://tests/voronoi_fracture_test.gd"
	"tornado_wind_field|cpu|-|-s res://tests/tornado_wind_field_test.gd"
	"cloth_wind|cpu|-|-s res://tests/cloth_wind_test.gd"
	"sim_step_clock|cpu|-|-s res://tests/sim_step_clock_test.gd"
	"nbody_values|cpu|-|-s res://tests/nbody_value_test.gd"
	"quality_profiles|cpu|-|-s res://tests/quality_profiles_test.gd"
	"ocean_buoyancy|cpu|-|-s res://tests/ocean_buoyancy_test.gd"
	"ocean_parameters|cpu|-|-s res://tests/ocean_parameter_test.gd"
	"ocean_coastal_config|cpu|-|-s res://tests/ocean_coastal_config_test.gd"
	"ocean_ssot|cpu|-|-s res://tests/ocean_ssot_test.gd"
	"alpine_terrain|cpu|-|-s res://tests/alpine_terrain_test.gd"
	"surface_ball|cpu|-|-s res://tests/surface_ball_test.gd"
	"smoke|cpu|-|-s res://tests/smoke_test.gd"
	"non_euclidean|gpu|-|-s res://tests/non_euclidean_runner.gd"
	"ocean_fft|gpu|600|-s res://tests/ocean_fft_test.gd"
	"ocean_physics|gpu|-|-s res://tests/ocean_physics_test.gd"
	"ocean_shore|gpu|-|-s res://tests/ocean_shore_test.gd"
	"ocean_island|gpu|-|-s res://tests/ocean_island_test.gd"
	"scene_cycle|gpu|-|-s res://tests/scene_cycle_test.gd"
	"smoke_gpu|gpu|-|-s res://tests/smoke_gpu_test.gd"
	"tornado_boot_look|gpu|-|-s res://tests/probe.gd -- tornado_boot_look"
	"tornado_wind_parity|gpu|-|-s res://tests/tornado_wind_parity_test.gd"
	"mixwell_parity|gpu|-|-s res://tests/mixwell_parity_test.gd"
	"sph_consistency|gpu|-|-s res://tests/sph_consistency_test.gd"
	"light_paste|gpu|-|-s res://tests/light_paste_test.gd"
	"spectral_gel|gpu|-|-s res://tests/spectral_gel_test.gd"
	"astral_fluid|gpu|-|-s res://tests/astral_fluid_test.gd"
	"liquid_nitrogen|gpu|-|-s res://tests/liquid_nitrogen_test.gd"
	"prismatic_slime|gpu|-|-s res://tests/prismatic_slime_test.gd"
	"terrain|gpu|300|-s res://tests/terrain_test.gd"
	"fluid_foam|gpu|-|-s res://tests/probe.gd -- fluid_foam"
	"fluid_tier|gpu|-|-s res://tests/probe.gd -- fluid_tier"
	"fluid_materials|gpu|-|-s res://tests/probe.gd -- fluid_materials"
	"fluid_honey_fall|gpu|-|-s res://tests/probe.gd -- fluid_honey_fall"
	"fire_cp_probe|gpu_unpaced|-|-s res://tests/fire_cp_probe_test.gd"
	"fire_combustion_balance|gpu_unpaced|-|-s res://tests/fire_combustion_balance_test.gd"
	"fire_water_balance|gpu_unpaced|600|-s res://tests/fire_water_balance_test.gd"
	"ui_smoke|ui|-|"
)

declare -a SUITE_NAMES=()
declare -A SUITE_KIND=()
declare -A SUITE_TIMEOUT=()
declare -A SUITE_ARGS=()
for entry in "${SUITES[@]}"; do
	IFS='|' read -r name kind timeout args <<<"$entry"
	SUITE_NAMES+=("$name")
	SUITE_KIND[$name]="$kind"
	SUITE_TIMEOUT[$name]="$timeout"
	SUITE_ARGS[$name]="$args"
done

usage() {
	sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

selected=()
for arg in "$@"; do
	case "$arg" in
		-h|--help) usage; exit 0 ;;
		--list)
			for name in "${SUITE_NAMES[@]}"; do
				printf '%-28s %s\n' "$name" "${SUITE_KIND[$name]}"
			done
			exit 0
			;;
		-*) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
		*)
			if [[ -z "${SUITE_KIND[$arg]:-}" ]]; then
				printf 'Unknown suite: %s (tests/run_tests.sh --list)\n' "$arg" >&2
				exit 2
			fi
			selected+=("$arg")
			;;
	esac
done
for var in JOBS GPU_JOBS TIMEOUT; do
	if ! [[ "${!var}" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid %s: %s\n' "$var" "${!var}" >&2
		exit 2
	fi
done

cpu_queue=()
gpu_queue=()
for name in "${SUITE_NAMES[@]}"; do
	if (( ${#selected[@]} > 0 )); then
		[[ " ${selected[*]} " == *" $name "* ]] || continue
	elif [[ "${SUITE_KIND[$name]}" != cpu && "${GPU:-0}" != "1" ]]; then
		continue
	fi
	if [[ "${SUITE_KIND[$name]}" == cpu ]]; then
		cpu_queue+=("$name")
	else
		gpu_queue+=("$name")
	fi
done

mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
export LOG_DIR
# A script error kills the suite coroutine without quitting, and a failed suite
# can hang in quit(): fail on either line instead of waiting out the timeout
# (inherited by run_ui_smoke.sh).
export PHYSICS_TEST_FAIL_PATTERN='^\(SCRIPT ERROR\|TEST FAIL\)'

# Before the shared lock: the build may run tools/import.sh, which takes it exclusive.
if ! GODOT="$GODOT" "$PROJECT_DIR/native/build.sh" >"$LOG_DIR/native_build.log" 2>&1; then
	printf 'Native build failed, see %s\n' "$LOG_DIR/native_build.log" >&2
	exit 1
fi

# Shared mode: hold this for the whole run so tools/import.sh waits instead of
# rewriting the script class cache under our feet. Shared locks between runners
# still let several agents test concurrently. The virtual display is exclusive
# instead: agents queue on .godot/virtual-display.lock for the whole GPU phase.
mkdir -p "$PROJECT_DIR/.godot"
exec 9>>"$PROJECT_DIR/.godot/import.lock"
flock -s 9

source "$SCRIPT_DIR/virtual_display.sh"

failed=()
active_pids=()
active_names=()
run_start=$SECONDS

cleanup() {
	local status=$?
	local pid
	for pid in "${active_pids[@]:-}"; do
		[[ -n "$pid" ]] && physics_test_process_stop "$pid"
	done
	physics_test_display_stop
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

suite_output() {
	local prefix="cpu"
	[[ "${SUITE_KIND[$1]}" == cpu ]] || prefix="gpu"
	printf '%s/%s-%s.stdout.log' "$LOG_DIR" "$prefix" "$1"
}

## Runs one suite to completion (in a background subshell) and leaves
## "<status> <seconds>" in <name>.result for report_suite.
run_suite() {
	local name="$1"
	local kind="${SUITE_KIND[$name]}"
	local output_file
	output_file="$(suite_output "$name")"
	local godot_log="${output_file%.stdout.log}.godot.log"
	local override="${name^^}_TIMEOUT"
	local timeout="${!override:-${SUITE_TIMEOUT[$name]}}"
	[[ "$timeout" == "-" ]] && timeout="$TIMEOUT"
	local -a args=()
	read -ra args <<<"${SUITE_ARGS[$name]}"
	local -a cmd=()
	case "$kind" in
		cpu)
			cmd=("$GODOT" --path "$PROJECT_DIR" --log-file "$godot_log" --headless
				--audio-driver Dummy --fixed-fps 30 --max-fps 30)
			;;
		gpu|gpu_unpaced)
			cmd=(env -u DISPLAY ${PHYSICS_TEST_X11_DISPLAY:+"DISPLAY=$PHYSICS_TEST_X11_DISPLAY"}
				XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR"
				WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY"
				"$GODOT" --path "$PROJECT_DIR" --log-file "$godot_log"
				--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER"
				--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER"
				--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER")
			if [[ "$kind" == gpu ]]; then
				cmd+=(--fixed-fps 30 --max-fps 30 --disable-vsync)
			fi
			if [[ -n "${PHYSICS_TEST_RESOLUTION:-}" ]]; then
				cmd+=(--resolution "$PHYSICS_TEST_RESOLUTION")
			fi
			;;
	esac
	local start=$SECONDS
	local status=0
	local sentinel=1
	if [[ "$kind" == ui ]]; then
		# Through the same setsid/group-kill primitive as the Godot suites, so
		# stopping the runner also stops the smoke's own Godot processes. Each
		# demo has its own $timeout inside; the outer one is only a backstop.
		physics_test_run_process "$((timeout * 40))" '^All [0-9]* demo(s) passed$' \
			"$output_file" env JOBS="$GPU_JOBS" GODOT="$GODOT" TIMEOUT="$timeout" \
			"$SCRIPT_DIR/run_ui_smoke.sh" || status=$?
		(( status == 0 )) || sentinel=0
	else
		physics_test_run_process "$timeout" "^TEST PASS ${name}\$" "$output_file" \
			"${cmd[@]}" "${args[@]}" || status=$?
		grep -q "^TEST PASS ${name}\$" "$output_file" || sentinel=0
	fi
	printf '%d %d %d\n' "$status" "$((SECONDS - start))" "$sentinel" >"$LOG_DIR/${name}.result"
}

## Prints the PASS line, or the FAIL line with its cause, the failed checks
## (push_error lines, engine exit-leak noise filtered) and the log path.
report_suite() {
	local name="$1"
	local status=1
	local seconds=0
	local sentinel=0
	local output_file
	output_file="$(suite_output "$name")"
	if [[ -f "$LOG_DIR/${name}.result" ]]; then
		read -r status seconds sentinel <"$LOG_DIR/${name}.result"
	fi
	if (( status == 0 && sentinel == 1 )); then
		printf 'TEST PASS %s (%ds)\n' "$name" "$seconds"
		return
	fi
	local reason
	if (( status == 124 )); then
		reason="timed out after ${seconds}s"
	elif grep -q '^TEST FAIL' "$output_file" 2>/dev/null; then
		reason="$(grep -m1 '^TEST FAIL' "$output_file" | sed 's/^TEST FAIL [^:]*: *//')"
	elif grep -q '^SCRIPT ERROR' "$output_file" 2>/dev/null; then
		reason="$(grep -m1 '^SCRIPT ERROR' "$output_file")"
	elif grep -q '^SMOKE FAIL' "$output_file" 2>/dev/null; then
		reason="$(grep -c '^SMOKE FAIL' "$output_file") demo(s) failed"
	elif (( status == 0 )); then
		reason="exited 0 without printing TEST PASS ${name}"
	else
		reason="$(physics_test_describe_status "$status")"
	fi
	printf 'TEST FAIL %s (%ds): %s\n' "$name" "$seconds" "$reason" >&2
	grep -E '^(ERROR: |SCRIPT ERROR|SMOKE FAIL)' "$output_file" 2>/dev/null \
		| grep -v -e 'leaked at exit' -e 'were never freed' -e 'resources still in use at exit' \
		| grep -vxF -- "$reason" | head -n 8 | sed 's/^/    /' >&2 || true
	printf '    log: %s\n' "$output_file" >&2
	failed+=("$name")
}

reap_oldest() {
	wait "${active_pids[0]}" || true
	report_suite "${active_names[0]}"
	active_pids=("${active_pids[@]:1}")
	active_names=("${active_names[@]:1}")
}

## Runs the named suites with at most $1 in flight, reporting in start order.
run_pool() {
	local max="$1"
	shift
	local name
	for name in "$@"; do
		run_suite "$name" &
		active_pids+=("$!")
		active_names+=("$name")
		while (( ${#active_pids[@]} >= max )); do
			reap_oldest
		done
	done
	while (( ${#active_pids[@]} > 0 )); do
		reap_oldest
	done
}

run_pool "$JOBS" "${cpu_queue[@]}"

# The GPU phase boots a virtual display and renders real frames — heavy, and it
# contends with everything else running on the machine. It is a last resort:
# opt in with GPU=1 (or name GPU suites) for compute suites (ocean FFT/physics,
# portal views), the fluid foam decay gate, the full scene cycle and the
# SimMenu touch smoke. Evidence captures are never part of the gate.
if (( ${#gpu_queue[@]} > 0 )); then
	if physics_test_display_start "$LOG_DIR/virtual-display.log"; then
		run_pool "$GPU_JOBS" "${gpu_queue[@]}"
		physics_test_display_stop
	else
		for name in "${gpu_queue[@]}"; do
			printf 'TEST FAIL %s: virtual display did not start (%s)\n' \
				"$name" "$LOG_DIR/virtual-display.log" >&2
			failed+=("$name")
		done
	fi
fi

total=$(( ${#cpu_queue[@]} + ${#gpu_queue[@]} ))
elapsed=$((SECONDS - run_start))
if (( ${#failed[@]} > 0 )); then
	printf 'Failed %d/%d suites in %ds: %s\n' "${#failed[@]}" "$total" "$elapsed" "${failed[*]}" >&2
	printf 'Logs: %s\n' "$LOG_DIR" >&2
	exit 1
fi
if (( ${#selected[@]} == 0 )) && [[ "${GPU:-0}" != "1" ]]; then
	printf 'CPU/value gates passed: %d suites in %ds (GPU suites skipped; run with GPU=1 to include them)\n' \
		"$total" "$elapsed"
else
	printf 'All %d suites passed in %ds\n' "$total" "$elapsed"
fi
