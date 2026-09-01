#!/usr/bin/env bash
# Runs CPU suites headless, then GPU suites in an invisible virtual Wayland display.
#
#   tests/run_tests.sh
#   GODOT=/path/to/godot JOBS=1 tests/run_tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-180}"
JOBS="${JOBS:-2}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-logs-$$}"

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	printf 'Invalid JOBS: %s\n' "$JOBS" >&2
	exit 2
fi
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
export LOG_DIR

source "$SCRIPT_DIR/virtual_display.sh"

failed=()
cpu_pids=()
cpu_names=()

cleanup() {
	local status=$?
	local pid
	for pid in "${cpu_pids[@]:-}"; do
		kill "$pid" 2>/dev/null || true
	done
	physics_test_display_stop
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run_cpu_suite() {
	local name="$1"
	local script="$2"
	local output_file="$LOG_DIR/cpu-${name}.stdout.log"
	local godot_log="$LOG_DIR/cpu-${name}.godot.log"
	local status=0

	physics_test_run_process "$TIMEOUT" "^TEST PASS $name$" "$output_file" \
		"$GODOT" --path "$PROJECT_DIR" \
			--log-file "$godot_log" --headless --audio-driver Dummy \
			-s "$script"
}

report_cpu_suite() {
	local name="$1"
	local status="$2"
	local output_file="$LOG_DIR/cpu-${name}.stdout.log"

	if (( status == 0 )); then
		printf 'TEST PASS %s\n' "$name"
		return
	fi
	if grep -q '^TEST FAIL' "$output_file"; then
		grep '^TEST FAIL' "$output_file" || true
	else
		printf 'TEST FAIL %s: crashed, timed out, or missing pass sentinel\n' "$name" >&2
	fi
	printf 'Log: %s\n' "$output_file" >&2
	failed+=("$name")
}

reap_cpu_suite() {
	local pid="${cpu_pids[0]}"
	local name="${cpu_names[0]}"
	local status=0
	if wait "$pid"; then
		status=0
	else
		status=$?
	fi
	report_cpu_suite "$name" "$status"
	cpu_pids=("${cpu_pids[@]:1}")
	cpu_names=("${cpu_names[@]:1}")
}

declare -a CPU_SUITES=(
	"ambient_fluid|res://tests/ambient_fluid_test.gd"
	"ambient_fluid_phase3|res://tests/ambient_fluid_phase3_test.gd"
	"ambient_fluid_phase4|res://tests/ambient_fluid_phase4_test.gd"
	"ambient_fluid_validation|res://tests/ambient_fluid_validation_test.gd"
	"ambient_fluid_preprocessor|res://tests/ambient_fluid_preprocessor_test.gd"
	"portal_math|res://tests/portal_math_test.gd"
	"growing_corridor_state|res://tests/growing_corridor_state_test.gd"
	"apparent_scale|res://tests/apparent_scale_test.gd"
	"wrap_world_state|res://tests/wrap_world_state_test.gd"
	"holonomy_state|res://tests/holonomy_state_test.gd"
	"fire_clock|res://tests/fire_clock_test.gd"
	"fractal_math|res://tests/fractal_math_test.gd"
	"fractal_de|res://tests/fractal_de_test.gd"
	"mixwell|res://tests/mixwell_test.gd"
	"gpu_timing_store|res://tests/gpu_timing_store_test.gd"
	"voronoi_fracture|res://tests/voronoi_fracture_test.gd"
	"tornado_wind_field|res://tests/tornado_wind_field_test.gd"
	"cloth_wind|res://tests/cloth_wind_test.gd"
)
for suite in "${CPU_SUITES[@]}"; do
	name="${suite%%|*}"
	script="${suite#*|}"
	run_cpu_suite "$name" "$script" &
	cpu_pids+=("$!")
	cpu_names+=("$name")
done
while (( ${#cpu_pids[@]} > 0 )); do
	reap_cpu_suite
done

if ! physics_test_display_start "$LOG_DIR/virtual-display.log"; then
	failed+=(non_euclidean ocean_fft scene_cycle ui_smoke)
else
	export PHYSICS_TEST_DISPLAY_DRIVER
	export PHYSICS_TEST_RENDERING_DRIVER
	export PHYSICS_TEST_AUDIO_DRIVER

	non_euclidean_output="$LOG_DIR/gpu-non_euclidean.stdout.log"
	non_euclidean_log="$LOG_DIR/gpu-non_euclidean.godot.log"
	non_euclidean_status=0
	physics_test_run_process "$TIMEOUT" '^TEST PASS non_euclidean$' "$non_euclidean_output" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--log-file "$non_euclidean_log" \
			-s res://tests/non_euclidean_runner.gd || non_euclidean_status=$?
	if (( non_euclidean_status == 0 )) && grep -q '^TEST PASS non_euclidean$' "$non_euclidean_output"; then
		printf 'TEST PASS non_euclidean\n'
	else
		printf 'TEST FAIL non_euclidean: crashed, timed out, or missing pass sentinel\n' >&2
		printf 'Log: %s\n' "$non_euclidean_output" >&2
		failed+=(non_euclidean)
	fi

	ocean_fft_output="$LOG_DIR/gpu-ocean_fft.stdout.log"
	ocean_fft_log="$LOG_DIR/gpu-ocean_fft.godot.log"
	ocean_fft_status=0
	physics_test_run_process "$TIMEOUT" '^TEST PASS ocean_fft$' "$ocean_fft_output" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--log-file "$ocean_fft_log" \
			-s res://tests/ocean_fft_test.gd || ocean_fft_status=$?
	if (( ocean_fft_status == 0 )) && grep -q '^TEST PASS ocean_fft$' "$ocean_fft_output"; then
		printf 'TEST PASS ocean_fft\n'
	else
		printf 'TEST FAIL ocean_fft: crashed, timed out, or missing pass sentinel\n' >&2
		printf 'Log: %s\n' "$ocean_fft_output" >&2
		failed+=(ocean_fft)
	fi

	scene_cycle_output="$LOG_DIR/gpu-scene_cycle.stdout.log"
	scene_cycle_log="$LOG_DIR/gpu-scene_cycle.godot.log"
	scene_cycle_status=0
	physics_test_run_process "$TIMEOUT" '^TEST PASS scene_cycle$' "$scene_cycle_output" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--log-file "$scene_cycle_log" \
			-s res://tests/scene_cycle_test.gd || scene_cycle_status=$?
	if (( scene_cycle_status == 0 )) && grep -q '^TEST PASS scene_cycle$' "$scene_cycle_output"; then
		printf 'TEST PASS scene_cycle\n'
	else
		printf 'TEST FAIL scene_cycle: crashed, timed out, or missing pass sentinel\n' >&2
		printf 'Log: %s\n' "$scene_cycle_output" >&2
		failed+=(scene_cycle)
	fi

	if ! JOBS="$JOBS" GODOT="$GODOT" TIMEOUT="$TIMEOUT" \
		PHYSICS_TEST_XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		PHYSICS_TEST_WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		PHYSICS_TEST_DISPLAY_DRIVER="$PHYSICS_TEST_DISPLAY_DRIVER" \
		PHYSICS_TEST_RENDERING_DRIVER="$PHYSICS_TEST_RENDERING_DRIVER" \
		PHYSICS_TEST_AUDIO_DRIVER="$PHYSICS_TEST_AUDIO_DRIVER" \
		"$SCRIPT_DIR/run_ui_smoke.sh"; then
		failed+=(ui_smoke)
	fi
	if ! GODOT="$GODOT" "$SCRIPT_DIR/run_mixwell_capture.sh"; then
		failed+=(mixwell_capture)
	fi
fi

if [[ ${#failed[@]} -gt 0 ]]; then
	printf 'Failed suites: %s\n' "${failed[*]}" >&2
	printf 'Logs: %s\n' "$LOG_DIR" >&2
	exit 1
fi
printf 'All suites passed\n'
