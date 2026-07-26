#!/usr/bin/env bash
# Runs the whole pass/fail suite: portal math and fire clock (headless), the
# non-euclidean integration tests, then the SimMenu touch smoke over every demo.
#
# tests/capture_non_euclidean.gd is deliberately not run here: it is an image
# inspection tool, not a pass/fail test.
#
#   tests/run_tests.sh
#   GODOT=/path/to/godot tests/run_tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"

failed=()

run_suite() {
	local name="$1"
	shift
	local output=""
	# Godot exits 0 even when a test pushes errors, so the PASS line is the verdict.
	output="$(timeout 300 "$GODOT" --path "$PROJECT_DIR" "$@" 2>&1 || true)"
	if printf '%s\n' "$output" | grep -q '^TEST PASS'; then
		printf 'TEST PASS %s\n' "$name"
	else
		printf '%s\n' "$output" | grep -E '^(TEST FAIL|ERROR)' >&2 || true
		printf 'TEST FAIL %s\n' "$name" >&2
		failed+=("$name")
	fi
}

run_suite portal_math --headless -s res://tests/portal_math_test.gd
run_suite fire_clock --headless --log-file /tmp/godot-fire-clock-suite.log -s res://tests/fire_clock_test.gd
run_suite non_euclidean -s res://tests/non_euclidean_runner.gd
GODOT="$GODOT" "$SCRIPT_DIR/run_ui_smoke.sh" || failed+=(ui_smoke)

if [[ ${#failed[@]} -gt 0 ]]; then
	printf 'Failed suites: %s\n' "${failed[*]}" >&2
	exit 1
fi
printf 'All suites passed\n'
