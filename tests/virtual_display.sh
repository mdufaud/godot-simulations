#!/usr/bin/env bash

PHYSICS_TEST_DISPLAY_PID=""
PHYSICS_TEST_DISPLAY_RUNTIME=""
PHYSICS_TEST_DISPLAY_SOCKET=""


physics_test_display_ready() {
	[[ -n "${PHYSICS_TEST_WAYLAND_DISPLAY:-}" ]] \
		&& [[ -n "${PHYSICS_TEST_XDG_RUNTIME_DIR:-}" ]] \
		&& [[ -S "${PHYSICS_TEST_XDG_RUNTIME_DIR}/${PHYSICS_TEST_WAYLAND_DISPLAY}" ]]
}


physics_test_display_start() {
	local log_file="$1"
	local kwin_bin="${KWIN:-kwin_wayland}"
	local runtime_dir
	local socket_name
	local width="${VIRTUAL_DISPLAY_WIDTH:-2560}"
	local height="${VIRTUAL_DISPLAY_HEIGHT:-1440}"

	if ! command -v "$kwin_bin" >/dev/null 2>&1; then
		printf 'GPU TEST FAIL: %s not found; refusing visible display fallback\n' "$kwin_bin" >&2
		return 1
	fi

	runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/physics-test-wayland.XXXXXX")"
	chmod 700 "$runtime_dir"
	socket_name="physics-test-${$}-${RANDOM}"

	XDG_RUNTIME_DIR="$runtime_dir" "$kwin_bin" \
		--virtual \
		--socket "$socket_name" \
		--width "$width" \
		--height "$height" \
		--no-lockscreen \
		--no-global-shortcuts \
		>"$log_file" 2>&1 &
	PHYSICS_TEST_DISPLAY_PID=$!
	PHYSICS_TEST_DISPLAY_RUNTIME="$runtime_dir"
	PHYSICS_TEST_DISPLAY_SOCKET="$socket_name"

	for _attempt in $(seq 1 100); do
		if [[ -S "$runtime_dir/$socket_name" ]]; then
			export PHYSICS_TEST_XDG_RUNTIME_DIR="$runtime_dir"
			export PHYSICS_TEST_WAYLAND_DISPLAY="$socket_name"
			export PHYSICS_TEST_DISPLAY_DRIVER="wayland"
			export PHYSICS_TEST_RENDERING_DRIVER="vulkan"
			export PHYSICS_TEST_AUDIO_DRIVER="Dummy"
			return 0
		fi
		if ! kill -0 "$PHYSICS_TEST_DISPLAY_PID" 2>/dev/null; then
			break
		fi
		sleep 0.1
	done

	printf 'GPU TEST FAIL: virtual Wayland compositor did not start\n' >&2
	sed -n '1,80p' "$log_file" >&2 || true
	physics_test_display_stop
	return 1
}


physics_test_display_stop() {
	if [[ -n "$PHYSICS_TEST_DISPLAY_PID" ]]; then
		kill "$PHYSICS_TEST_DISPLAY_PID" 2>/dev/null || true
		wait "$PHYSICS_TEST_DISPLAY_PID" 2>/dev/null || true
	fi
	if [[ -n "$PHYSICS_TEST_DISPLAY_RUNTIME" && -d "$PHYSICS_TEST_DISPLAY_RUNTIME" ]]; then
		rm -rf -- "$PHYSICS_TEST_DISPLAY_RUNTIME"
	fi
	PHYSICS_TEST_DISPLAY_PID=""
	PHYSICS_TEST_DISPLAY_RUNTIME=""
	PHYSICS_TEST_DISPLAY_SOCKET=""
}


physics_test_process_alive() {
	local state
	state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')"
	[[ -n "$state" && "$state" != Z* ]]
}


physics_test_process_stop() {
	local pid="$1"
	if ! physics_test_process_alive "$pid"; then
		wait "$pid" 2>/dev/null || true
		return
	fi
	kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
	for _attempt in $(seq 1 20); do
		if ! physics_test_process_alive "$pid"; then
			break
		fi
		sleep 0.1
	done
	if physics_test_process_alive "$pid"; then
		kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true
}


physics_test_run_process() {
	local timeout_seconds="$1"
	local pass_pattern="$2"
	local output_file="$3"
	local process_pid=""
	local deadline
	local grace_deadline
	local status=0
	shift 3

	local data_dir
	data_dir="$(mktemp -d "${output_file}.data.XXXXXX")" || return 1
	XDG_DATA_HOME="$data_dir" setsid "$@" >"$output_file" 2>&1 &
	process_pid=$!
	trap 'if [[ -n "${process_pid:-}" ]]; then physics_test_process_stop "$process_pid"; fi; exit 130' INT TERM
	deadline=$((SECONDS + timeout_seconds))

	while :; do
		if grep -q -- "$pass_pattern" "$output_file" 2>/dev/null; then
			grace_deadline=$((SECONDS + ${TEST_EXIT_GRACE:-2}))
			while physics_test_process_alive "$process_pid" && (( SECONDS < grace_deadline )); do
				sleep 0.1
			done
			if physics_test_process_alive "$process_pid"; then
				physics_test_process_stop "$process_pid"
			else
				wait "$process_pid" 2>/dev/null || true
			fi
			trap - INT TERM
			return 0
		fi

		if ! physics_test_process_alive "$process_pid"; then
			wait "$process_pid" 2>/dev/null || status=$?
			trap - INT TERM
			return "$status"
		fi

		if (( SECONDS >= deadline )); then
			physics_test_process_stop "$process_pid"
			trap - INT TERM
			return 124
		fi
		sleep 0.1
	done
}
