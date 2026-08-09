#!/bin/bash

# Define variables
hyprdir=$HOME/.config/hypr
monitor=$1
wallpaper=$2 # This is passed as an argument to the script

# Apply wallpaper directly (hyprpaper 0.8+ no longer requires preload)
hyprctl hyprpaper wallpaper "$monitor,$wallpaper"

sleep 1 # Wait for wallpaper to be set (removes stuttering)

# static wallpaper replaces mpvpaper
for pid in $(pgrep -x mpvpaper); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "$monitor"; then
        kill "$pid" 2>/dev/null
    fi
done

# engine layer would cover this
"$hyprdir/wallpaper-daemon/stop-engine.sh" "$monitor" 2>/dev/null

# Set wallpaper theme
"$hyprdir/theme/scripts/wal-theme.sh" "$wallpaper"
