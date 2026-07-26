#!/usr/bin/env bash
# Runs the SimMenu touch-path smoke test over every demo, one Godot process each
# (GPU compute demos do not survive sharing a RenderingDevice across scenes).
# Needs a real GPU: --headless gives a null RenderingDevice here.
#
#   tests/run_ui_smoke.sh              # all demos
#   tests/run_ui_smoke.sh fire_demo    # one demo
#   RESOLUTION=1080x2340 tests/run_ui_smoke.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
RESOLUTION="${RESOLUTION:-2340x1080}"
TIMEOUT="${TIMEOUT:-180}"

DEMOS=(
	ssr_demo ocean_demo fire_demo nbody_demo grass_demo parallax_demo
	fluid_demo fractal_demo fractal_3d_demo tornado_demo sand_demo
	cloth_demo destruction_demo non_euclidean_demo planet_demo
)
if [[ $# -gt 0 ]]; then
	DEMOS=("$@")
fi

failed=()
for demo in "${DEMOS[@]}"; do
	output=""
	if ! output="$(FORCE_TOUCH_UI=1 timeout "$TIMEOUT" "$GODOT" --path "$PROJECT_DIR" \
			--resolution "$RESOLUTION" res://tests/ui_smoke.tscn -- "$demo" 2>&1)"; then
		printf '%s\n' "$output" | grep '^SMOKE FAIL' || printf 'SMOKE FAIL %s: crashed or timed out\n' "$demo"
		failed+=("$demo")
		continue
	fi
	printf '%s\n' "$output" | grep '^SMOKE PASS'
done

if [[ ${#failed[@]} -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}" >&2
	exit 1
fi
printf 'All %d demo(s) passed\n' "${#DEMOS[@]}"
