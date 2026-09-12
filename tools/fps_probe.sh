#!/usr/bin/env bash
# Measure a demo's average fps under one quality tier on the virtual Wayland
# compositor (real GPU, Vulkan, vsync off). Calibration helper for the quality
# tiers; not part of the test gate.
#
#   tools/fps_probe.sh nbody_demo medium
#   tools/fps_probe.sh ocean_demo low 1920x1080 6
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-120}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-fpsprobe-$$}"

TARGET="${1:?usage: tools/fps_probe.sh <demo_key> <low|medium|high|ultra> [WxH] [seconds]}"
TIER="${2:?usage: tools/fps_probe.sh <demo_key> <low|medium|high|ultra> [WxH] [seconds]}"
SIZE="${3:-1920x1080}"
SECONDS_ARG="${4:-5}"

mkdir -p "$LOG_DIR"
source "$PROJECT_DIR/tests/virtual_display.sh"

cleanup() {
	local status=$?
	physics_test_display_stop
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! physics_test_display_start "$LOG_DIR/virtual-display.log" >/dev/null; then
	printf 'fps_probe: virtual display failed to start; see %s\n' "$LOG_DIR/virtual-display.log" >&2
	exit 1
fi

status=0
physics_test_run_process "$TIMEOUT" '^FPS PROBE ' "$LOG_DIR/probe.stdout.log" \
	env -u DISPLAY \
	XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
	WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
	"$GODOT" --path "$PROJECT_DIR" \
		--display-driver wayland \
		--rendering-driver vulkan \
		--audio-driver Dummy \
		--log-file "$LOG_DIR/probe.godot.log" \
		-s res://tools/fps_probe.gd -- \
		"target=$TARGET" "tier=$TIER" "size=$SIZE" "seconds=$SECONDS_ARG" || status=$?

if rg -q 'SCRIPT ERROR:|FPS PROBE FAIL' "$LOG_DIR/probe.stdout.log"; then
	status=1
fi
if (( status != 0 )); then
	printf 'fps_probe: failed (exit %d); logs in %s\n' "$status" "$LOG_DIR" >&2
	sed -n '1,40p' "$LOG_DIR/probe.stdout.log" >&2 || true
	exit "$status"
fi

grep '^FPS PROBE ' "$LOG_DIR/probe.stdout.log"
