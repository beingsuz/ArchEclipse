#!/bin/bash
#
# wallpaperengine-ctl.sh <command...>
#
# Broadcasts a live control command to every running per-monitor engine so
# option/property/speed changes apply instantly (no restart). Screen-scoped
# commands (scaling/clamp/property) get the monitor inserted automatically;
# everything else (speed/volume/mute/set ...) is passed through as-is.

[ -n "$1" ] || exit 0

for sock in "${XDG_RUNTIME_DIR:-/tmp}"/lwe-*.sock; do
    [ -S "$sock" ] || continue
    monitor="${sock##*/lwe-}"
    monitor="${monitor%.sock}"

    case "$1" in
        scaling|clamp|property) cmd="$1 $monitor ${*:2}" ;;
        *)                      cmd="$*" ;;
    esac

    printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
done
