#!/bin/bash
# wallpaperengine-ctl.sh <command...>
#
# Live control command to the engine; screen-scoped ones get the
# monitor inserted. Exit 1 if nothing accepted it.

[ -n "$1" ] || exit 0

rt="${XDG_RUNTIME_DIR:-/tmp}"
found_socket=0
delivered=0
last_response=""

send() { # send <sock> <cmd>
    local response
    response="$(printf '%s\n' "$2" | timeout 2 socat - "UNIX-CONNECT:$1" 2>/dev/null | tr -d '\r\n')"
    last_response="$response"
    case "$response" in
        ""|error*|"unknown command"*) return 1 ;;
    esac
    return 0
}

# Shared engine (one daemon, all monitors): screen-scoped commands are sent
# once per monitor over the same socket.
if [ -S "$rt/lwe.sock" ]; then
    found_socket=1
    case "$1" in
        scaling|clamp|property)
            for monitor in $(hyprctl monitors -j | jq -r '.[].name'); do
                send "$rt/lwe.sock" "$1 $monitor ${*:2}" && delivered=$((delivered + 1))
            done
            ;;
        *)
            send "$rt/lwe.sock" "$*" && delivered=$((delivered + 1))
            ;;
    esac
fi

# Per-monitor engines (legacy layout, or a mid-migration session).
for sock in "$rt"/lwe-*.sock; do
    [ -S "$sock" ] || continue
    found_socket=1
    monitor="${sock##*/lwe-}"
    monitor="${monitor%.sock}"

    case "$1" in
        scaling|clamp|property) cmd="$1 $monitor ${*:2}" ;;
        *)                      cmd="$*" ;;
    esac

    send "$sock" "$cmd" && delivered=$((delivered + 1))
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
