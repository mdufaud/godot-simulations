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
	"lfm|180|^TEST PASS lfm$|LFM PROBE "
	"fluid_foam|180|^TEST PASS fluid_foam$|FLUFOAM "
	"fluid_resize|120|^FLU3 PROBE DONE|FLU3 "
	"fluid_tier|180|^TEST PASS fluid_tier$|FLUTIER "
	"fractal_policy|300|^POLICY PROBE PASS$|POLICY "
	"fractal_zoom|300|^FR2 PROBE DONE|FR2 "
	"grass|120|^GRA3 PROBE DONE|GRA3 "
	"mixopt|180|^MIXOPT PROBE DONE ok$|MIXOPT "
	"tornado_boot_look|180|^TEST PASS tornado_boot_look$|"
	"fps|120|^FPS PROBE target=|FPS PROBE "
	"foam_convergence|600|^FOAM CONVERGENCE DONE|FOAM "
	"foam_histogram|300|^HISTO DONE|HISTO "
	"ocean_freeze|120|^TEST PASS ocean_freeze$|OCEAN FREEZE "
	"ocean_ultra|180|^TEST PASS ocean_ultra$|OCEAN ULTRA "
	"ocean_single_wave|120|^TEST PASS ocean_single_wave$|OCEAN WAVE "
)

usage() {
	printf 'usage: tests/probe.sh list\n'
	printf '       tests/probe.sh <name> [args...]\n'
	printf '       tests/probe.sh fps <demo> <low|medium|high|ultra> [WxH] [seconds]\n'
	printf '       tests/probe.sh fps target=... tier=... [size=...] [seconds=...]\n'
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
	physics_test_run_process "$timeout_seconds" "$PROBE_SENTINEL" "$stdout_log" \
		env -u DISPLAY \
		XDG_RUNTIME_DIR="$PHYSICS_TEST_XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$PHYSICS_TEST_WAYLAND_DISPLAY" \
		"$GODOT" --path "$PROJECT_DIR" \
			--display-driver "$PHYSICS_TEST_DISPLAY_DRIVER" \
			--rendering-driver "$PHYSICS_TEST_RENDERING_DRIVER" \
			--audio-driver "$PHYSICS_TEST_AUDIO_DRIVER" \
			--log-file "$godot_log" \
			-s res://tests/probe.gd -- "$name" "$@" || status=$?

	if grep -q 'SCRIPT ERROR:' "$stdout_log" 2>/dev/null; then
		status=1
	elif (( status == 0 )) && ! grep -q -- "$PROBE_SENTINEL" "$stdout_log" 2>/dev/null; then
		status=1
	fi
	if (( status != 0 )); then
		printf 'probe: %s failed (exit %d); logs in %s\n' "$name" "$status" "$LOG_DIR" >&2
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
