#!/bin/sh
# Build heartbeat / stall detector for the opencode Debian build.
#
# The build has long silent stretches (a large vite build of the web UI,
# then a synchronous brotli-11 compression of the archive, then Bun's
# bytecode compilation), which look like a hung build to output-inactivity
# watchdogs on slow arm64 workers. This script, run in the background by
# debian/rules, prints every HEARTBEAT_INTERVAL seconds (default 600):
#
#   - system load, available memory and the kernel oom_kill counter delta,
#   - a snapshot of the build processes (state, %cpu, command).
#
# An arm64 build previously sat with load 0.00 and all build processes idle
# for ~50 minutes until the inactivity watchdog killed it. So after two
# consecutive samples without any runnable (R-state) build process, the
# script also dumps each build process's wait site (kernel wait channel,
# first syscall argument, RSS) so a silent hang leaves a diagnosable log:
#   - a bun/esbuild process in S state waiting in futex_*: userspace lock
#     deadlock (file an upstream issue with the heartbeat excerpt),
#   - a missing esbuild/bun child + oom_kills incremented: the kernel
#     OOM-killed a build worker and its parent is waiting on a dead pipe
#     (the arm64 worker needs more memory),
#   - all processes in R state at ~100%% cpu: the build is CPU-bound and
#     merely slow (raise the watchdog timeout or use a faster builder).
#
# HEARTBEAT_INTERVAL can override the period (seconds) for testing.
# Run from the source tree root; terminate by killing this script.

interval=${HEARTBEAT_INTERVAL:-600}
count=0
stall=0
prev_oom=$(awk '/^oom_kill/ {print $2}' /proc/vmstat 2>/dev/null || echo 0)

while :; do
	sleep "$interval"
	count=$((count + 1))

	oom=$(awk '/^oom_kill/ {print $2}' /proc/vmstat 2>/dev/null || echo 0)
	oom_delta=$((oom - prev_oom))
	prev_oom=$oom

	load=$(cut -d' ' -f1-3 /proc/loadavg)
	mem=$(awk '/^MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
	echo "==> [heartbeat $count] load $load, mem avail ${mem:-?}MB, oom_kills $oom_delta"
	echo "==> [heartbeat $count] build processes (state, %cpu, command):"
	ps -eo stat,pcpu,comm 2>/dev/null | grep -E 'bun|node|esbuild|vite' | head -5

	# ps unavailable (minimal chroot): report and keep beating.
	if ! command -v ps >/dev/null 2>&1; then
		echo "==> [heartbeat $count] ps unavailable, stall detection disabled"
		continue
	fi

	# A CPU-active build shows R-state build processes in most samples; two
	# consecutive all-idle samples look like a hang: dump the wait sites.
	if ps -eo stat,comm 2>/dev/null |
		awk '/bun|node|esbuild|vite/ && /^R/ { found = 1 } END { if (found) exit 0; exit 1 }'
	then
		stall=0
	else
		stall=$((stall + 1))
	fi

	if [ "$stall" -ge 2 ]; then
		echo "==> [heartbeat $count] WARNING: no runnable build process for $stall samples; dumping wait sites:"
		for pid in $(ps -eo pid,comm 2>/dev/null | awk '/bun|node|esbuild|vite/ {print $1}' | head -8); do
			comm=$(cat /proc/$pid/comm 2>/dev/null)
			wchan=$(cat /proc/$pid/wchan 2>/dev/null)
			rss=$(awk '/^VmRSS/ {print $2}' /proc/$pid/status 2>/dev/null)
			syscall=$(cut -d' ' -f1 /proc/$pid/syscall 2>/dev/null)
			echo "    pid $pid comm=${comm:-?} wchan=${wchan:-?} rss=${rss:-?}KB syscall=${syscall:-?}"
		done
	fi
done
