#!/bin/bash
# wallpaperengine-restart.sh
#
# Restart + re-apply, for changes the socket cannot push live (GPU target,
# engine binary update). One shared engine drives all monitors (lwe.sock);
# the per-monitor sockets are handled too for a mid-migration session.

daemon="$HOME/.config/hypr/wallpaper-daemon"
rt="${XDG_RUNTIME_DIR:-/tmp}"

kill_sock() {
    [ -S "$1" ] || return 1
    pkill -f -- "--control-socket $1" 2>/dev/null
    rm -f "$1"
    return 0
}

killed=0
kill_sock "$rt/lwe.sock" && killed=1
for monitor in $(hyprctl monitors -j | jq -r '.[].name'); do
    kill_sock "$rt/lwe-$monitor.sock" && killed=1
done

# Engine alive but socket gone: kill by verified binary, never by name.
if [ "$killed" -eq 0 ]; then
    for pid in $(pgrep -x kirie); do
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        case "$exe" in "$HOME/.local/bin/kirie"*) kill "$pid" ;; esac
    done
fi

sleep 0.3
for monitor in $(hyprctl monitors -j | jq -r '.[].name'); do
    "$daemon/apply-current.sh" "$monitor"
done
