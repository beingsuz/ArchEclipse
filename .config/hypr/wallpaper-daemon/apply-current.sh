#!/bin/bash
# apply-current.sh <monitor> [--print]
#
# Applies (or prints) the wallpaper a monitor should show, per the
# configured mode and primary fallback. Mirrors resolve_wallpaper().

hyprDir="$HOME/.config/hypr"
monitor="$1"
# --print: resolve only (used by the engine's cold start)
print_only=""
[ "$2" = "--print" ] && print_only=1
[ -z "$monitor" ] && { echo "Usage: apply-current.sh <monitor> [--print]" >&2; exit 1; }

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
[ -n "$print_only" ] && { printf '%s\n' "$wallpaper"; exit 0; }

exec "$hyprDir/wallpaper-daemon/dispatch.sh" "$monitor" "$wallpaper"
