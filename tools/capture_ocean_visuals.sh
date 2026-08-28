#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-/home/mdufaud/.local/bin/godot}"
OUT_DIR="${1:-$PROJECT_DIR/docs/images/comparisons/ocean_2026-08-27}"
PHASE="${2:-final}"
PHASE_DIR="$OUT_DIR/$PHASE"
RESOLUTION="${RESOLUTION:-1280x720}"
FRAMES="${FRAMES:-180}"
EVERY="${EVERY:-60}"
CONTROL_FRAMES="${CONTROL_FRAMES:-120}"
WARMUP="${WARMUP:-90}"
DT="${DT:-0.016666667}"
CAPTURE_TIME="${CAPTURE_TIME:-20.0}"
# Fix plan 0.6: seconds of LIVE simulation before the first capture so the foam
# feedback is at equilibrium (persistence ~4 s in storm; equilibrium ~13-17 s).
FOAM_WARMUP="${FOAM_WARMUP:-16.0}"
WIND_DIRECTION="${WIND_DIRECTION:-0.0}"
LOOK="${LOOK:-1}"
SUN_ELEVATION="${SUN_ELEVATION:-34.0}"
SUN_AZIMUTH="${SUN_AZIMUTH:-160.0}"
DIAGNOSTICS="${DIAGNOSTICS:-true}"
CONTROLS="${CONTROLS:-true}"
FULL="${FULL:-true}"

mkdir -p "$PHASE_DIR/full" "$PHASE_DIR/controls" "$PHASE_DIR/pairs"
if [[ ! -f "$OUT_DIR/manifest.tsv" || "${RESET_MANIFEST:-false}" == "true" ]]; then
	printf 'phase\tstate\tpreset\tmood\tlook\tview\ttime\tdt\twind_direction\tsun_elevation\tsun_azimuth\n' \
		> "$OUT_DIR/manifest.tsv"
fi

"$GODOT" --path "$PROJECT_DIR" --log-file "$OUT_DIR/import-${PHASE}.godot.log" \
	--headless --import >/dev/null

state_names=(calm breeze swell storm)
presets=(0 1 2 3)
moods=(0 0 0 1)
IFS=',' read -r -a states <<< "${STATES:-calm,breeze,swell,storm}"
IFS=',' read -r -a views <<< "${VIEWS:-overhead,low_crest,horizon}"

common_args() {
	local preset="$1"
	local mood="$2"
	local view="$3"
	local look="${4:-$LOOK}"
	printf '%s\n' \
		"preset=$preset" "backend=1" "look=$look" "mood=$mood" \
		"mood_snap=1" "lightning=0" "view=$view" "ui=0" "time=$CAPTURE_TIME" \
		"dt=$DT" "warmup=$WARMUP" "foam_warmup=$FOAM_WARMUP" \
		"wind=$WIND_DIRECTION" \
		"sun_elevation=$SUN_ELEVATION" "sun_azimuth=$SUN_AZIMUTH" \
		"rain=0" "spray=0" "interaction=0"
}

capture_state_view() {
	local state="$1"
	local preset="$2"
	local mood="$3"
	local view="$4"
	local output="$5"
	shift 5
	local state_look="$LOOK"
	[[ "$state" == "storm" ]] && state_look=2
	mapfile -t args < <(common_args "$preset" "$mood" "$view" "$state_look")
	rm -f "$output"
	"$SCRIPT_DIR/capture.sh" ocean_demo "$output" "$FRAMES" "$EVERY" \
		profile=1 coverage=1 "${args[@]}" "$@" 2>&1 | tee -a "$PHASE_DIR/capture.log"
}

capture_pair() {
	local state="$1"
	local preset="$2"
	local mood="$3"
	local look="$4"
	local view="$5"
	local output="$6"
	local pair_sun_elevation="$7"
	local pair_sun_azimuth="$8"
	mapfile -t args < <(common_args "$preset" "$mood" "$view")
	args+=("look=$look" "sun_elevation=$pair_sun_elevation" "sun_azimuth=$pair_sun_azimuth")
	rm -f "$output"
	"$SCRIPT_DIR/capture.sh" ocean_demo "$output" "$FRAMES" "$EVERY" \
		profile=1 coverage=1 "${args[@]}" 2>&1 | tee -a "$PHASE_DIR/capture.log"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$PHASE" "$state" "$preset" "$mood" "$look" "$view" \
		"$CAPTURE_TIME" "$DT" "$WIND_DIRECTION" "$pair_sun_elevation" \
		"$pair_sun_azimuth" >> "$OUT_DIR/manifest.tsv"
}

if [[ "$FULL" == "true" ]]; then
	for i in "${!states[@]}"; do
		state="${states[$i]}"
		state_index=-1
		for candidate in "${!state_names[@]}"; do
			if [[ "${state_names[$candidate]}" == "$state" ]]; then
				state_index="$candidate"
				break
			fi
		done
		if (( state_index < 0 )); then
			printf 'Unknown state: %s\n' "$state" >&2
			exit 2
		fi
		preset="${presets[$state_index]}"
		mood="${moods[$state_index]}"
		for view in "${views[@]}"; do
			capture_state_view "$state" "$preset" "$mood" "$view" \
				"$PHASE_DIR/full/${state}_${view}.png"
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$PHASE" "$state" "$preset" "$mood" "$LOOK" "$view" \
				"$CAPTURE_TIME" "$DT" "$WIND_DIRECTION" "$SUN_ELEVATION" \
				"$SUN_AZIMUTH" \
				>> "$OUT_DIR/manifest.tsv"
		done
	done
fi

if [[ "$CONTROLS" == "true" ]]; then
	for i in "${!states[@]}"; do
		state="${states[$i]}"
		state_index=-1
		for candidate in "${!state_names[@]}"; do
			if [[ "${state_names[$candidate]}" == "$state" ]]; then
				state_index="$candidate"
				break
			fi
		done
		if (( state_index < 0 )); then
			printf 'Unknown state: %s\n' "$state" >&2
			exit 2
		fi
		preset="${presets[$state_index]}"
		mood="${moods[$state_index]}"
		state_look="$LOOK"
		[[ "$state" == "storm" ]] && state_look=2
		base=("$CONTROL_FRAMES" 0)
		for control in no_foam no_micro no_reflection geometry normals crest breaking foam_fresh foam_persistent; do
			args=("foam=1" "micro=1" "reflection=1" "debug=0" "clouds=0")
			case "$control" in
				no_foam) args+=("foam=0") ;;
				no_micro) args+=("micro=0") ;;
				no_reflection) args+=("reflection=0") ;;
				geometry) args+=("debug=1") ;;
				normals) args+=("debug=2") ;;
				crest) args+=("debug=3") ;;
				breaking) args+=("debug=7") ;;
				foam_fresh) args+=("debug=5") ;;
				foam_persistent) args+=("debug=6") ;;
			esac
			mapfile -t common < <(common_args "$preset" "$mood" low_crest "$state_look")
			output="$PHASE_DIR/controls/${state}_${control}.png"
			rm -f "$output"
			"$SCRIPT_DIR/capture.sh" ocean_demo \
				"$output" "${base[@]}" \
				profile=0 "${common[@]}" "${args[@]}" 2>&1 | tee -a "$PHASE_DIR/capture.log"
		done
	done
fi

if [[ "${PAIRS:-true}" == "true" ]]; then
	capture_pair swell 2 0 1 low_crest "$PHASE_DIR/pairs/swell_day.png" 34.0 160.0
	capture_pair swell 2 0 0 sun "$PHASE_DIR/pairs/swell_sun.png" 8.0 180.0
	capture_pair storm 3 1 2 low_crest "$PHASE_DIR/pairs/storm_overcast.png" 9.0 180.0
	capture_pair storm 3 1 0 low_crest "$PHASE_DIR/pairs/storm_backlight.png" 8.0 180.0
fi

if [[ "$DIAGNOSTICS" == "true" ]]; then
	printf 'ocean campaign phase=%s output=%s resolution=%s frames=%s every=%s warmup=%s foam_warmup=%s dt=%s capture_time=%s wind=%s look=%s sun=%s/%s\n' \
		"$PHASE" "$OUT_DIR" "$RESOLUTION" "$FRAMES" "$EVERY" "$WARMUP" \
		"$FOAM_WARMUP" "$DT" \
		"$CAPTURE_TIME" "$WIND_DIRECTION" "$LOOK" "$SUN_ELEVATION" "$SUN_AZIMUTH" \
		> "$OUT_DIR/run-${PHASE}.txt"
	{
		printf 'phase=%s\n' "$PHASE"
		printf 'command=%q %q %q\n' "$0" "$OUT_DIR" "$PHASE"
		printf 'resolution=%s frames=%s every=%s warmup=%s dt=%s\n' \
			"$RESOLUTION" "$FRAMES" "$EVERY" "$WARMUP" "$DT"
	} >> "$OUT_DIR/run.txt"
fi
