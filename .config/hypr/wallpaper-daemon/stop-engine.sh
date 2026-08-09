#!/bin/bash
# stop-engine.sh <monitor>|all
#
# Stops the engine and waits for exit. Matched by /proc/<pid>/exe,
# never by cmdline (that also matches the calling shell). One engine
# serves every monitor, so the others are re-applied afterwards.

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

# bring the other monitors back
if [ "$target" != all ] && command -v hyprctl >/dev/null 2>&1; then
    for m in $(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null); do
        [ "$m" = "$target" ] && continue
        w="$("$(dirname "$0")/apply-current.sh" "$m" --print 2>/dev/null)"
        [ -n "$w" ] && [ -f "$(dirname "$w")/project.json" ] || continue
        setsid "$(dirname "$0")/wallpaperengine.sh" "$m" "$w" >/dev/null 2>&1 9>&- </dev/null &
    done
fi
exit 0
