#!/usr/bin/env bash
# Screenshot a demo on an isolated virtual Wayland compositor (real GPU, Vulkan),
# so no window opens on the desktop. PNGs are meant for visual inspection.
#
#   tools/capture.sh ocean_demo                                # res://tmp/capture.png
#   tools/capture.sh ocean_demo tmp/ocean.png 240              # after 240 frames
#   tools/capture.sh ocean_demo tmp/ocean_seq.png 240 80       # shot every 80 frames
#   tools/capture.sh res://scenes/ocean_demo.tscn out.png 120  # any scene path
#
# Output paths are project-relative, res:// paths or absolute. Frame counts beat
# wall time: the grab happens exactly N process frames after the demo is added.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
RESOLUTION="${RESOLUTION:-1280x720}"
TIMEOUT="${TIMEOUT:-90}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-capture-$$}"

TARGET="${1:?usage: tools/capture.sh <demo_key|res://scene.tscn> [out.png] [frames] [every]}"
OUT="${2:-res://tmp/capture.png}"
FRAMES="${3:-120}"
EVERY="${4:-0}"
EXTRA_ARGS=("${@:5}")

if [[ "$OUT" != res://* && "$OUT" != /* ]]; then
	OUT="res://$OUT"
fi

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
	printf 'capture: virtual display failed to start; see %s\n' "$LOG_DIR/virtual-display.log" >&2
	exit 1
fi

status=0
physics_test_run_process "$TIMEOUT" '^CAPTURE DONE' "$LOG_DIR/capture.stdout.log" \
	env -u DISPLAY \
	XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
	WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
	"$GODOT" --path "$PROJECT_DIR" \
		--display-driver wayland \
		--rendering-driver vulkan \
		--audio-driver Dummy \
		--resolution "$RESOLUTION" \
		--log-file "$LOG_DIR/capture.godot.log" \
		-s res://tools/capture_demo.gd -- \
		"target=$TARGET" "out=$OUT" "frames=$FRAMES" "every=$EVERY" \
		"size=$RESOLUTION" "${EXTRA_ARGS[@]}" || status=$?

if (( status != 0 )); then
	printf 'capture: failed (exit %d); logs in %s\n' "$status" "$LOG_DIR" >&2
	sed -n '1,40p' "$LOG_DIR/capture.stdout.log" >&2 || true
	exit "$status"
fi

grep -E '^CAPTURE (CONFIG|COVERAGE|META|IMAGE|SHOT) ' "$LOG_DIR/capture.stdout.log" \
	| sed -e 's/^CAPTURE SHOT /wrote /'
