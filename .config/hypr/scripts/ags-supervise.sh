#!/bin/bash
#
# ags-supervise.sh <ags-bin> <log> [pid-file]
#
# Keeps the shell alive. Nothing else does: bar.sh starts it and exits, so a
# shell that dies — a GTK crash, or a startup that throws while the only
# monitor is off and Hyprland is showing its FALLBACK output — leaves the
# desktop with no bar until someone notices and restarts it by hand.
#
# Deliberate shutdowns are left alone. `ags quit` exits 0, and bar.sh signals
# the previous shell when a newer one takes over; both mean "stop", not
# "restart", or two supervisors would fight over one desktop.

set -uo pipefail

BIN="$1"
LOG="$2"
PID_FILE="${3:-}"
[ -x "$BIN" ] || { echo "ags-supervise: '$BIN' not executable" >&2; exit 1; }

# Give up on a shell that cannot even stay up this long, but keep trying with
# a widening gap — a desktop with no bar should heal itself once whatever
# broke (a missing library after an update, an output still settling) is gone.
MIN_HEALTHY_SECONDS=15
backoff=2
MAX_BACKOFF=60

trap 'kill "${child:-0}" 2>/dev/null; exit 0' TERM INT HUP

# A newer bar.sh records its own supervisor here. Standing down when the file
# no longer names us keeps a stale supervisor from resurrecting an old shell
# alongside the new one.
superseded() {
    [ -n "$PID_FILE" ] && [ -r "$PID_FILE" ] || return 1
    [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && return 1
    return 0
}

while :; do
    superseded && exit 0
    started=$(date +%s)
    "$BIN" >>"$LOG" 2>&1 &
    child=$!
    wait "$child"
    rc=$?
    ran=$(( $(date +%s) - started ))

    # 0 = `ags quit`; 129/130/143 = HUP/INT/TERM, which is bar.sh handing over
    # to a newer shell or the session ending.
    case "$rc" in
        0 | 129 | 130 | 143)
            exit 0
            ;;
    esac

    if [ "$ran" -ge "$MIN_HEALTHY_SECONDS" ]; then
        backoff=2
    fi

    printf '%s ags-supervise: shell exited %s after %ss — restarting in %ss\n' \
        "$(date -Is)" "$rc" "$ran" "$backoff" >>"$LOG"
    superseded && exit 0
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
done
