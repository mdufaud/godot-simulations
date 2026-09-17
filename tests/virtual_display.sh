#!/usr/bin/env bash

PHYSICS_TEST_DISPLAY_PID=""
PHYSICS_TEST_DISPLAY_RUNTIME=""
PHYSICS_TEST_DISPLAY_SOCKET=""
PHYSICS_TEST_DISPLAY_LOCK_FILE=""


physics_test_display_ready() {
	[[ -n "${PHYSICS_TEST_WAYLAND_DISPLAY:-}" ]] \
		&& [[ -n "${PHYSICS_TEST_XDG_RUNTIME_DIR:-}" ]] \
		&& [[ -S "${PHYSICS_TEST_XDG_RUNTIME_DIR}/${PHYSICS_TEST_WAYLAND_DISPLAY}" ]]
}


## Serialize the virtual Wayland display across concurrent agents: the lock is
## held from start to stop and released by the kernel even if a holder dies.
## Waiters queue instead of racing the compositor (PHYSICS_TEST_DISPLAY_WAIT
## caps the wait, default 1800s).
physics_test_display_lock_acquire() {
	local lock_file
	lock_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.godot/virtual-display.lock"
	mkdir -p "$(dirname "$lock_file")"
	local wait_seconds="${PHYSICS_TEST_DISPLAY_WAIT:-1800}"
	exec 8>>"$lock_file"
	if ! flock -n 8; then
		local holder
		holder="$(cat "$lock_file" 2>/dev/null || true)"
		printf 'GPU TEST: virtual display busy%s; waiting up to %ss\n' \
			"${holder:+ (holder pid $holder)}" "$wait_seconds" >&2
		if ! flock -w "$wait_seconds" 8; then
			printf 'GPU TEST FAIL: virtual display still busy after %ss\n' "$wait_seconds" >&2
			exec 8>&- 2>/dev/null || true
			return 1
		fi
	fi
	printf '%s\n' "$$" >"$lock_file"
	PHYSICS_TEST_DISPLAY_LOCK_FILE="$lock_file"
}


physics_test_display_lock_release() {
	if [[ -n "$PHYSICS_TEST_DISPLAY_LOCK_FILE" ]]; then
		: >"$PHYSICS_TEST_DISPLAY_LOCK_FILE" 2>/dev/null || true
		flock -u 8 2>/dev/null || true
		exec 8>&- 2>/dev/null || true
		PHYSICS_TEST_DISPLAY_LOCK_FILE=""
	fi
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

	if ! physics_test_display_lock_acquire; then
		return 1
	fi

	runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/physics-test-wayland.XXXXXX")"
	chmod 700 "$runtime_dir"
	socket_name="physics-test-${$}-${RANDOM}"

	# setsid gives the compositor its own process group so the stop path can
	# take down kwin and its XWayland children together. The socket is an
	# absolute path: a session XDG_RUNTIME_DIR leaking through setsid would
	# otherwise resolve the bare name outside the watched runtime dir.
	XDG_RUNTIME_DIR="$runtime_dir" setsid "$kwin_bin" \
		--virtual \
		--socket "$runtime_dir/$socket_name" \
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
		# The setsid wrapper forks and exits when the caller is already a group
		# leader, so its pid dying says nothing: track kwin by its socket name.
		if ! pgrep -f -- "--socket $runtime_dir/$socket_name" >/dev/null 2>&1; then
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
	physics_test_display_lock_release
	if [[ -n "$PHYSICS_TEST_DISPLAY_PID" ]]; then
		# TERM then KILL the whole compositor process group: a bare TERM to the
		# leader leaks kwin children that keep holding a Vulkan device.
		physics_test_process_stop "$PHYSICS_TEST_DISPLAY_PID"
	fi
	# Safety net for the forked-setsid edge: the socket name is unique per run,
	# and with an absolute --socket path the name alone still matches the
	# compositor cmdline (a "--socket <name>" prefix would not).
	if [[ -n "$PHYSICS_TEST_DISPLAY_SOCKET" ]]; then
		pkill -KILL -f -- "$PHYSICS_TEST_DISPLAY_SOCKET" 2>/dev/null || true
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
				# Sentinel printed but the process will not exit on its own:
				# reap it and honour the sentinel.
				physics_test_process_stop "$process_pid"
				trap - INT TERM
				return 0
			fi
			# A crash after printing the sentinel is still a failure.
			wait "$process_pid" 2>/dev/null || status=$?
			trap - INT TERM
			return "$status"
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
