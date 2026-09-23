#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-180}"
# Shared lock on the import cache, same convention as the gate runners.
mkdir -p "$PROJECT_DIR/.godot"
exec 9>>"$PROJECT_DIR/.godot/import.lock"
flock -s 9

source "$SCRIPT_DIR/virtual_display.sh"

LOG_DIR="${MIXWELL_CAPTURE_DIR:-${TMPDIR:-/tmp}/physics-test-mixwell-capture-$$}"
mkdir -p "$LOG_DIR"
capture_args=()
if [[ -n "${MIXWELL_PRESET:-}" ]]; then
	capture_args+=("${MIXWELL_PRESET}")
fi
if [[ -n "${MIXWELL_BOUNDARY:-}" ]]; then
	capture_args+=("${MIXWELL_BOUNDARY}")
fi
if [[ "${MIXWELL_GPU_ORACLE:-0}" == "1" ]]; then
	capture_args+=("oracle")
fi
if [[ "${MIXWELL_GPU_AB:-0}" == "1" ]]; then
	capture_args+=("gpu_ab")
fi
if [[ "${MIXWELL_DIAGNOSTICS:-0}" == "1" ]]; then
	capture_args+=("diagnostics")
fi
if [[ "${MIXWELL_DRAG:-0}" == "1" ]]; then
	capture_args+=("drag")
fi
if [[ -n "${MIXWELL_EXAMPLE:-}" ]]; then
	capture_args+=("example=${MIXWELL_EXAMPLE}")
fi
if [[ -n "${MIXWELL_DRAG_COUNT:-}" ]]; then
	capture_args+=("drag_count=${MIXWELL_DRAG_COUNT}")
fi
owns_display=0
if ! physics_test_display_ready; then
	physics_test_display_start "$LOG_DIR/display.log"
	owns_display=1
fi
cleanup() {
	local status=$?
	if (( owns_display )); then
		physics_test_display_stop
	fi
	if (( status == 0 )) && [[ "${KEEP_MIXWELL_CAPTURE_ARTIFACTS:-0}" != "1" ]]; then
		rm -rf "$LOG_DIR"
	elif (( status != 0 )); then
		printf 'MIXWELL CAPTURE FAIL: logs in %s\n' "$LOG_DIR" >&2
	fi
}
trap cleanup EXIT

run_capture() {
	local output="$1"
	local pass_pattern="$2"
	local stdout_file="$LOG_DIR/$(basename "$output").stdout"
	local status=0
	physics_test_run_process "$TIMEOUT" "$pass_pattern" "$stdout_file" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--resolution 640x360 --log-file "$LOG_DIR/$(basename "$output").log" \
			-s res://tools/mixwell_capture.gd -- "$output" "${capture_args[@]}" || status=$?
	cat "$stdout_file" 2>/dev/null || true
	if (( status != 0 )); then
		printf 'MIXWELL CAPTURE FAIL: %s exited %d\n' "$(basename "$output")" "$status" >&2
	fi
	return "$status"
}

if [[ "${MIXWELL_GPU_ORACLE:-0}" == "1" ]]; then
	oracle_output="$LOG_DIR/oracle.png"
	run_capture "$oracle_output" '^MIXWELL GPU ORACLE ' || exit 1
	grep -q '^MIXWELL GPU ORACLE ' "$LOG_DIR/oracle.png.stdout" || exit 1
	exit 0
fi

if [[ "${MIXWELL_GPU_AB:-0}" == "1" ]]; then
	ab_output="$LOG_DIR/ab.png"
	run_capture "$ab_output" '^MIXWELL GPU A/B ' || exit 1
	grep -q '^MIXWELL GPU A/B ' "$LOG_DIR/ab.png.stdout" || exit 1
	exit 0
fi

if [[ "${MIXWELL_DIAGNOSTICS:-0}" == "1" ]]; then
	diagnostics_output="$LOG_DIR/diagnostics.png"
	run_capture "$diagnostics_output" '^MIXWELL DIAGNOSTICS ' || exit 1
	grep -q '^MIXWELL DIAGNOSTICS ' "$LOG_DIR/diagnostics.png.stdout" || exit 1
	exit 0
fi

first="$LOG_DIR/first.png"
second="$LOG_DIR/second.png"
run_capture "$first" '^MIXWELL CAPTURE DONE$' || exit 1
run_capture "$second" '^MIXWELL CAPTURE DONE$' || exit 1
grep -q '^MIXWELL CAPTURE DONE$' "$LOG_DIR/first.png.stdout" || exit 1
grep -q '^MIXWELL CAPTURE DONE$' "$LOG_DIR/second.png.stdout" || exit 1
if ! cmp -s "$first" "$second"; then
	printf 'MIXWELL CAPTURE FAIL: non-deterministic PNG output\n' >&2
	exit 1
fi
printf 'MIXWELL CAPTURE PASS %s\n' "$(sha256sum "$first" | cut -d' ' -f1)"
