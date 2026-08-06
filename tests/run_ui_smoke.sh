#!/usr/bin/env bash
# Runs SimMenu touch-path smoke tests in an isolated virtual Wayland display.
# GPU processes stay separate because compute demos do not share a RenderingDevice.
#
#   tests/run_ui_smoke.sh
#   tests/run_ui_smoke.sh fire_demo planet_demo
#   JOBS=1 tests/run_ui_smoke.sh
#   RESOLUTION=1080x2340 tests/run_ui_smoke.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
RESOLUTION="${RESOLUTION:-2340x1080}"
TIMEOUT="${TIMEOUT:-180}"
JOBS="${JOBS:-2}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-logs-$$}"

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	printf 'Invalid JOBS: %s\n' "$JOBS" >&2
	exit 2
fi
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

DEMOS=(
	ssr_demo ocean_demo fire_demo nbody_demo grass_demo parallax_demo
	fluid_demo fractal_demo fractal_3d_demo tornado_demo sand_demo
	cloth_demo destruction_demo non_euclidean_demo planet_demo
)
if [[ $# -gt 0 ]]; then
	DEMOS=("$@")
fi

source "$SCRIPT_DIR/virtual_display.sh"

owns_display=0
active_pids=()
active_names=()
active_outputs=()
failed=()

cleanup() {
	local status=$?
	local pid
	for pid in "${active_pids[@]:-}"; do
		kill "$pid" 2>/dev/null || true
	done
	if (( owns_display )); then
		physics_test_display_stop
	fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! physics_test_display_ready; then
	if ! physics_test_display_start "$LOG_DIR/virtual-display.log"; then
		exit 1
	fi
	owns_display=1
fi

run_demo() {
	local demo="$1"
	local output_file="$LOG_DIR/ui-${demo}.stdout.log"
	local godot_log="$LOG_DIR/ui-${demo}.godot.log"

	physics_test_run_process "$TIMEOUT" "^SMOKE PASS $demo$" "$output_file" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		FORCE_TOUCH_UI=1 \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--resolution "$RESOLUTION" \
			--log-file "$godot_log" \
			res://tests/ui_smoke.tscn -- "$demo"
}

report_demo() {
	local demo="$1"
	local status="$2"
	local output_file="$LOG_DIR/ui-${demo}.stdout.log"

	if (( status == 0 )); then
		printf 'SMOKE PASS %s\n' "$demo"
		return
	fi
	if grep -q '^SMOKE FAIL' "$output_file"; then
		grep '^SMOKE FAIL' "$output_file" || true
	else
		printf 'SMOKE FAIL %s: crashed, timed out, or missing pass sentinel\n' "$demo"
	fi
	printf 'Log: %s\n' "$output_file" >&2
	failed+=("$demo")
}

reap_one() {
	local pid="${active_pids[0]}"
	local demo="${active_names[0]}"
	local status=0
	if wait "$pid"; then
		status=0
	else
		status=$?
	fi
	report_demo "$demo" "$status"
	active_pids=("${active_pids[@]:1}")
	active_names=("${active_names[@]:1}")
	active_outputs=("${active_outputs[@]:1}")
}

for demo in "${DEMOS[@]}"; do
	run_demo "$demo" &
	active_pids+=("$!")
	active_names+=("$demo")
	active_outputs+=("$LOG_DIR/ui-${demo}.stdout.log")
	if (( ${#active_pids[@]} >= JOBS )); then
		reap_one
	fi
done
while (( ${#active_pids[@]} > 0 )); do
	reap_one
done

if [[ ${#failed[@]} -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}" >&2
	printf 'Logs: %s\n' "$LOG_DIR" >&2
	exit 1
fi
printf 'All %d demo(s) passed\n' "${#DEMOS[@]}"
