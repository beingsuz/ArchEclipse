#!/bin/bash
#
# set-wallpaper.sh <slot> <monitor> [wallpaper]
#
# <slot> is a workspace number, "global" (the one wallpaper used in Global mode)
# or "primary" (the fallback shown where nothing is set). Each is stored in the
# monitor's defaults.conf under its own key: w-<number>=, global=, primary=.

hyprDir="$HOME/.config/hypr"
slot="$1"
monitor="$2"
wallpaper="$3"

if [ -z "$slot" ] || [ -z "$monitor" ]; then
    echo "Usage: set-wallpaper.sh <slot|global|primary> <monitor> [wallpaper]"
    exit 1
fi

if [ -z "$wallpaper" ]; then
    wallpaper="$(find "$HOME/.config/wallpapers/defaults" -type f | shuf -n 1)"
    if [ -z "$wallpaper" ]; then
        echo "Failed to pick a random wallpaper"
        exit 1
    fi
fi

current_config="$hyprDir/wallpaper-daemon/config/$monitor/defaults.conf"
if [ ! -f "$current_config" ]; then
    echo "Config not found for monitor '$monitor': $current_config"
    exit 1
fi

case "$slot" in
    global|primary) key="$slot" ;;
    *) key="w-${slot}" ;;
esac

read_key() { grep "^$1=" "$current_config" | cut -d'=' -f2- | head -n 1; }

current_workspace="$(hyprctl monitors -j | jq -r --arg monitor "$monitor" '.[] | select(.name == $monitor) | .activeWorkspace.id')"

if ! grep -q "^${key}=" "$current_config"; then
    echo "${key}=" >> "$current_config"
fi

old_wallpaper="$(read_key "$key")"
if [ "$old_wallpaper" = "$wallpaper" ]; then
    echo "Wallpaper is already set to $wallpaper"
    exit 0
fi

# Which slot the monitor is showing right now: in Global mode always "global",
# otherwise the wallpaper of the active workspace.
settings="$HOME/.config/ags/cache/settings/settings.json"
mode="workspace"
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
    m="$(jq -r '(.wallpaper.mode.value) // "workspace"' "$settings" 2>/dev/null)"
    [ -n "$m" ] && [ "$m" != "null" ] && mode="$m"
fi

if [ "$mode" = "global" ]; then
    active_slot="global"
    active_key="global"
else
    active_slot="$current_workspace"
    active_key="w-${current_workspace}"
fi

# Render only what is on screen: the slot being shown, or "primary" when that
# slot has no wallpaper of its own and the fallback is what is visible.
if [ "$slot" = "$active_slot" ] ||
    { [ "$slot" = "primary" ] && [ -z "$(read_key "$active_key")" ]; }; then
    wallpaper_ext="${wallpaper##*.}"
    wallpaper_ext="$(printf '%s' "$wallpaper_ext" | tr '[:upper:]' '[:lower:]')"

    # A Wallpaper Engine item is a Steam Workshop folder (project.json next to
    # the preview picked in the switcher), not a plain image or video file.
    if [ -f "$(dirname "$wallpaper")/project.json" ]; then
        "$hyprDir/wallpaper-daemon/wallpaperengine.sh" "$monitor" "$wallpaper" &
    elif [ "$wallpaper_ext" = "gif" ] || [ "$wallpaper_ext" = "mp4" ] || [ "$wallpaper_ext" = "webm" ]; then
        "$hyprDir/wallpaper-daemon/mpvpaper.sh" "$monitor" "$wallpaper" &
    else
        "$hyprDir/wallpaper-daemon/hyprpaper.sh" "$monitor" "$wallpaper" &
    fi
fi

sed -i "s|^${key}=.*|${key}=${wallpaper}|" "$current_config"
