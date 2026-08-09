#!/bin/bash
# wallpaperengine-ctl.sh <command...>
#
# Live control command to the engine; screen-scoped ones get the
# monitor inserted. Exit 1 if nothing accepted it.

[ -n "$1" ] || exit 0

found_socket=0
delivered=0
last_response=""

for sock in "${XDG_RUNTIME_DIR:-/tmp}"/lwe-*.sock; do
    [ -S "$sock" ] || continue
    found_socket=1
    monitor="${sock##*/lwe-}"
    monitor="${monitor%.sock}"

    case "$1" in
        scaling|clamp|property) cmd="$1 $monitor ${*:2}" ;;
        *)                      cmd="$*" ;;
    esac

    response="$(printf '%s\n' "$cmd" | timeout 2 socat - "UNIX-CONNECT:$sock" 2>/dev/null | tr -d '\r\n')"
    last_response="$response"

    case "$response" in
        # no reply or rejection -> not delivered
        ""|error*|"unknown command"*) continue ;;
    esac
    delivered=$((delivered + 1))
done

if [ "$found_socket" = 0 ]; then
    echo "no-socket"
    exit 1
fi
if [ "$delivered" -eq 0 ]; then
    echo "${last_response:-rejected}"
    exit 1
fi
exit 0
