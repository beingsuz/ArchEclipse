#!/bin/bash
#
# stop-engine.sh <monitor>|all
#
# Stops the kirie wallpaper engine bound to <monitor> (or every kirie engine
# with "all") and waits for it to actually exit, so the control socket is
# really free before a caller starts something else on the output.
#
# Engines are matched by /proc/<pid>/exe basename, never by grepping command
# lines: a cmdline pattern like "--screen-root HDMI-A-1" also matches the
# calling shell itself when it carries the same string.

target="$1"
[ -n "$target" ] || { echo "usage: stop-engine.sh <monitor>|all" >&2; exit 1; }

engine_pids() {
    local p exe pid
    for p in /proc/[0-9]*/exe; do
        exe="$(readlink "$p" 2>/dev/null)" || continue
        [ "$(basename "$exe")" = kirie ] || continue
        pid="${p#/proc/}"; pid="${pid%/exe}"
        if [ "$target" = all ]; then
            echo "$pid"
        else
            # Trailing space anchors the monitor name so HDMI-A-1 does not
            # also match HDMI-A-10.
            tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null |
                grep -q -- "--screen-root $target " && echo "$pid"
        fi
    done
}

pids="$(engine_pids)"
[ -n "$pids" ] || exit 0

kill $pids 2>/dev/null
for _ in $(seq 1 30); do
    [ -n "$(engine_pids)" ] || exit 0
    sleep 0.1
done
kill -9 $(engine_pids) 2>/dev/null
exit 0
