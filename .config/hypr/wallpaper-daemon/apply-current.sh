#!/bin/bash
#
# apply-current.sh <monitor>
#
# Resolves and applies the wallpaper that *should* be shown on a monitor right
# now, honoring the configured mode (Global vs Per Workspace) and the primary
# fallback. Mirrors resolve_wallpaper() in wallpaper-loop.c. Used by the UI to
# apply changes (e.g. switching mode) immediately for any wallpaper type.

hyprDir="$HOME/.config/hypr"
monitor="$1"
[ -z "$monitor" ] && { echo "Usage: apply-current.sh <monitor>" >&2; exit 1; }

conf="$hyprDir/wallpaper-daemon/config/$monitor/defaults.conf"
[ -f "$conf" ] || exit 0

settings="$HOME/.config/ags/cache/settings/settings.json"
read_key() { grep "^$1=" "$conf" | cut -d'=' -f2- | head -n 1; }

mode="workspace"
src="workspace1"
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
    m="$(jq -r '(.wallpaper.mode.value) // "workspace"' "$settings" 2>/dev/null)"
    [ -n "$m" ] && [ "$m" != "null" ] && mode="$m"
    s="$(jq -r '(.wallpaper.primarySource.value) // "workspace1"' "$settings" 2>/dev/null)"
    [ -n "$s" ] && [ "$s" != "null" ] && src="$s"
fi

ws="$(hyprctl monitors -j | jq -r --arg m "$monitor" \
    '.[] | select(.name == $m) | .activeWorkspace.id')"

wallpaper=""
if [ "$mode" = "global" ]; then
    wallpaper="$(read_key global)"
else
    wallpaper="$(read_key "w-${ws}")"
fi

if [ -z "$wallpaper" ]; then
    [ "$src" = "custom" ] && wallpaper="$(read_key primary)"
    [ -z "$wallpaper" ] && wallpaper="$(read_key w-1)"
fi

[ -z "$wallpaper" ] && exit 0

ext="${wallpaper##*.}"
ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
case "$wallpaper" in
    */workshop/content/431960/*)
        exec "$hyprDir/wallpaper-daemon/wallpaperengine.sh" "$monitor" "$wallpaper"
        ;;
    *)
        if [ "$ext" = "gif" ] || [ "$ext" = "mp4" ] || [ "$ext" = "webm" ]; then
            exec "$hyprDir/wallpaper-daemon/mpvpaper.sh" "$monitor" "$wallpaper"
        else
            exec "$hyprDir/wallpaper-daemon/hyprpaper.sh" "$monitor" "$wallpaper"
        fi
        ;;
esac
