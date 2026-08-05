#!/bin/bash

# Define variables
hyprdir=$HOME/.config/hypr
monitor=$1
wallpaper=$2

if [ -z "$monitor" ] || [ -z "$wallpaper" ]; then
    echo "Usage: mpvpaper.sh <monitor> <wallpaper>" >&2
    exit 1
fi

# unload any existing wallpaper on this monitor (hyprpaper 0.8+ no longer requires unload)
# hyprctl hyprpaper unload "$monitor" >/dev/null 2>&1

# Stop any existing mpvpaper instance on this monitor
for pid in $(pgrep -x mpvpaper); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "$monitor"; then
        kill "$pid" 2>/dev/null
    fi
done

# Stop any Wallpaper Engine bound to this monitor: its layer sits above
# mpvpaper and would keep covering the video wallpaper started below.
"$hyprdir/wallpaper-daemon/wallpaperengine.sh" stop "$monitor" 2>/dev/null

# Playback speed from the shell settings (1 = normal). Read here rather than
# passed in, so the daemon and the switcher both get it without a new argument.
settings="$HOME/.config/ags/cache/settings/settings.json"
speed="1"
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
    s="$(jq -r '(.wallpaper.playbackSpeed.value) // 1' "$settings" 2>/dev/null)"
    [ -n "$s" ] && [ "$s" != "null" ] && speed="$s"
fi

# Start mpvpaper in background for animated/video wallpapers
nohup mpvpaper -o "no-audio --loop --fs --panscan=1.0 --speed=$speed" "$monitor" "$wallpaper" >/dev/null 2>&1 &

sleep 1 # Wait for wallpaper to be set (removes stuttering)

"$hyprdir/theme/scripts/wal-theme.sh" "$wallpaper" >/dev/null 2>&1

exit 0

