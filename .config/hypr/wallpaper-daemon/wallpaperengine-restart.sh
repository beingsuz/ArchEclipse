#!/bin/bash
# wallpaperengine-restart.sh
#
# Restart + re-apply, for changes the socket cannot push live.

daemon="$HOME/.config/hypr/wallpaper-daemon"

for monitor in $(hyprctl monitors -j | jq -r '.[].name'); do
    sock="${XDG_RUNTIME_DIR:-/tmp}/lwe-$monitor.sock"
    [ -S "$sock" ] || continue
    pkill -f -- "--control-socket $sock" 2>/dev/null
    rm -f "$sock"
    "$daemon/apply-current.sh" "$monitor"
done
