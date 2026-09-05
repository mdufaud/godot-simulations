#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${1:-$PROJECT_DIR/tmp/ocean_phase0_baseline}"
GODOT="${GODOT:-/home/mdufaud/.local/bin/godot}"
TIMEOUT="${TIMEOUT:-180}"
WARMUP="${WARMUP:-120}"
FRAMES="${FRAMES:-240}"
DT="${DT:-0.016666667}"
CAPTURE_TIME="${CAPTURE_TIME:-20.0}"
WIND_DIRECTION="${WIND_DIRECTION:-0.0}"
LOOK="${LOOK:-1}"
SUN_ELEVATION="${SUN_ELEVATION:-34.0}"
SUN_AZIMUTH="${SUN_AZIMUTH:-160.0}"

mkdir -p "$OUT_DIR/raw"
printf 'state\tprofile\tvram_mb\tsim_median_ms\tsim_p95_ms\tfoam_median_ms\tfoam_p95_ms\tfoam_near_gpu_ms\tquery_gpu_ms\tviewport_median_ms\tviewport_p95_ms\twater_coverage\tcrest_coverage\tbreaking_coverage\tfoam_coverage\n' \
	> "$OUT_DIR/baseline.tsv"
: > "$OUT_DIR/runs.log"

state_names=(calm breeze swell storm)
presets=(0 1 2 3)
moods=(0 0 0 1)
profile_names=(performance high ultra)
IFS=',' read -r -a states <<< "${STATES:-calm,breeze,swell,storm}"
IFS=',' read -r -a profiles <<< "${PROFILES:-high,performance,ultra}"
IFS=',' read -r -a resolutions <<< "${RESOLUTIONS:-1280x720}"

field() {
	local key="$1"
	local line="$2"
	printf '%s\n' "$line" | tr ' ' '\n' | awk -F= -v wanted="$key" '$1 == wanted { print $2; exit }'
}

resolution_size() {
	case "$1" in
		1280x720) printf '1280 720\n' ;;
		1920x1080) printf '1920 1080\n' ;;
		3840x2160) printf '3840 2160\n' ;;
		*) return 1 ;;
	esac
}

for resolution in "${resolutions[@]}"; do
	read -r display_width display_height < <(resolution_size "$resolution")
	for profile in "${profiles[@]}"; do
		i=-1
		for candidate in "${!profile_names[@]}"; do
			if [[ "${profile_names[$candidate]}" == "$profile" ]]; then
				i="$candidate"
				break
			fi
		done
		if (( i < 0 )); then
			printf 'Unknown profile: %s\n' "$profile" >&2
			exit 2
		fi
		for state in "${states[@]}"; do
			s=-1
			for candidate in "${!state_names[@]}"; do
				if [[ "${state_names[$candidate]}" == "$state" ]]; then
					s="$candidate"
					break
				fi
			done
			if (( s < 0 )); then
				printf 'Unknown state: %s\n' "$state" >&2
				exit 2
			fi
			preset="${presets[$s]}"
			mood="${moods[$s]}"
			output="$OUT_DIR/raw/${state}_${profile}_${resolution}.png"
			printf 'RUN state=%s profile=%s resolution=%s\n' "$state" "$profile" "$resolution" | tee -a "$OUT_DIR/runs.log"
			capture_output=$(VIRTUAL_DISPLAY_WIDTH="$display_width" \
				VIRTUAL_DISPLAY_HEIGHT="$display_height" RESOLUTION="$resolution" \
				TIMEOUT="$TIMEOUT" GODOT="$GODOT" \
				"$SCRIPT_DIR/capture.sh" ocean_demo "$output" "$FRAMES" 0 \
				profile=1 coverage=1 preset="$preset" backend=1 look="$LOOK" \
				quality="$profile" \
				mood="$mood" mood_snap=1 lightning=0 view=overhead ui=0 \
				time="$CAPTURE_TIME" dt="$DT" warmup="$WARMUP" wind="$WIND_DIRECTION" \
				sun_elevation="$SUN_ELEVATION" sun_azimuth="$SUN_AZIMUTH" \
				foam=1 micro=1 reflection=1 rain=0 spray=0 interaction=0 2>&1) || {
				printf '%s\n' "$capture_output" | tee -a "$OUT_DIR/runs.log" >&2
				exit 1
			}
			printf '%s\n' "$capture_output" >> "$OUT_DIR/runs.log"
			meta=$(printf '%s\n' "$capture_output" | awk '/^CAPTURE META / { line = $0 } END { print line }')
			coverage=$(printf '%s\n' "$capture_output" | awk '/^CAPTURE COVERAGE / { line = $0 } END { sub(/^.*water=/, "", line); print line }')
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$state" "$profile" "$(field vram_mb "$meta")" \
				"$(field sim_gpu "$meta")" "$(field sim_gpu_p95 "$meta")" \
				"$(field foam_gpu "$meta")" "$(field foam_gpu_p95 "$meta")" \
				"$(field foam_near_gpu "$meta")" "$(field query_gpu "$meta")" \
				"$(field viewport_gpu "$meta")" "$(field viewport_gpu_p95 "$meta")" \
				"${coverage:--1}" "$(field crest_cov "$meta")" \
				"$(field breaking_cov "$meta")" "$(field foam_cov "$meta")" \
				>> "$OUT_DIR/baseline.tsv"
		done
	done
done

awk -F '\t' '
NR == 1 {
		print "# Ocean Phase 0 GPU baseline"
		print ""
		print "| State | Profile | VRAM MB | Sim median | Sim p95 | Foam median | Foam p95 | Near foam GPU | Query GPU | Viewport median | Viewport p95 | Water coverage | Crest coverage | Breaking coverage | Foam coverage |"
		print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
		next
}
{
	printf "| %s | %s | %s | %s ms | %s ms | %s ms | %s ms | %s ms | %s ms | %s ms | %s ms | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15
}
' "$OUT_DIR/baseline.tsv" > "$OUT_DIR/baseline.md"
printf 'Baseline written: %s\n' "$OUT_DIR/baseline.tsv"
