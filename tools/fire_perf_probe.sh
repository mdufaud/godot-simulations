#!/usr/bin/env bash
# Fire performance probe on the virtual Wayland compositor (real GPU, Vulkan,
# vsync off). Lot-K baseline helper: p50/p95 frame times at a fixed size plus
# memory, solver state and pool occupancy. Not part of the test gate.
#
#   tools/fire_perf_probe.sh label=wood
#   tools/fire_perf_probe.sh label=p32 pressure=32 size=2560x1440 seconds=8
#   tools/fire_perf_probe.sh label=atlas4096 pool=3
#   tools/fire_perf_probe.sh -e FIRE_DISPLAY_F16=1 label=f16
#
# -e VAR=VALUE prefixes pass environment variables to the probe process
# (repeatable); every other argument goes to the probe script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-300}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/physics-test-perfprobe-$$}"

ENV_ARGS=()
PROBE_ARGS=()
while (( $# > 0 )); do
	if [[ "$1" == "-e" ]]; then
		shift
		ENV_ARGS+=("$1")
	else
		PROBE_ARGS+=("$1")
	fi
	shift
done

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
	printf 'fire_perf_probe: virtual display failed to start; see %s\n' "$LOG_DIR/virtual-display.log" >&2
	exit 1
fi

status=0
physics_test_run_process "$TIMEOUT" '^PERF ' "$LOG_DIR/probe.stdout.log" \
	env -u DISPLAY ${PHYSICS_TEST_X11_DISPLAY:+"DISPLAY=$PHYSICS_TEST_X11_DISPLAY"} \
	XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
	WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
	"${ENV_ARGS[@]}" \
	"$GODOT" --path "$PROJECT_DIR" \
		--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
		--rendering-driver vulkan \
		--audio-driver Dummy \
		--resolution 2560x1440 \
		--log-file "$LOG_DIR/probe.godot.log" \
		-s res://tools/fire_perf_probe.gd -- \
		"${PROBE_ARGS[@]}" || status=$?

if rg -q 'SCRIPT ERROR:|PERF FAIL' "$LOG_DIR/probe.stdout.log"; then
	status=1
fi
if (( status != 0 )); then
	printf 'fire_perf_probe: failed (exit %d); logs in %s\n' "$status" "$LOG_DIR" >&2
	sed -n '1,40p' "$LOG_DIR/probe.stdout.log" >&2 || true
	exit "$status"
fi

grep -E '^PERF ' "$LOG_DIR/probe.stdout.log"
