#!/bin/bash
#
# wallpaperengine.sh <monitor> <preview>
#
# Applies a Steam Wallpaper Engine item. A persistent per-monitor engine process
# is driven over a Unix control socket, so changing wallpaper is a live swap
# (no restart). A new process is only started when one isn't already running for
# the monitor. <preview> is the item's preview at <workshop>/<id>/preview.*.

hyprdir="$HOME/.config/hypr"
daemon="$hyprdir/wallpaper-daemon"
settings="$HOME/.config/ags/cache/settings/settings.json"

monitor="$1"
preview="$2"
[ -z "$monitor" ] || [ -z "$preview" ] && { echo "usage: wallpaperengine.sh <monitor> <preview>" >&2; exit 1; }

dir="$(dirname "$preview")"          # workshop item folder = the wallpaper
id="$(basename "$dir")"
sock="${XDG_RUNTIME_DIR:-/tmp}/lwe-$monitor.sock"

bin="$HOME/linux-wallpaperengine/build/output/linux-wallpaperengine"
[ -x "$bin" ] || bin="$(command -v linux-wallpaperengine)" || {
    notify-send -u critical "Wallpaper Engine" "linux-wallpaperengine is not installed" 2>/dev/null; exit 1; }

we()   { jq -r "($1) // empty" "$settings" 2>/dev/null; }
send() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:$sock" 2>/dev/null; }

# Push this wallpaper's saved property overrides to the running engine.
push_props() {
    local f="$daemon/config/properties/$id.conf"
    [ -f "$f" ] || return
    while IFS='=' read -r k v; do
        [ -n "$k" ] && send "property $monitor $k $v"
    done < "$f"
}

# Engine can't render this item (web/3D-model/asset) -> show its preview.
fallback() {
    notify-send "Wallpaper Engine" "'$id' can't be rendered — showing its preview." 2>/dev/null
    case "${preview##*.}" in
        gif|webm|mp4|GIF|WEBM|MP4) "$daemon/mpvpaper.sh" "$monitor" "$preview" ;;
        *)                         "$daemon/hyprpaper.sh" "$monitor" "$preview" ;;
    esac
}

theme() { "$hyprdir/theme/scripts/wal-theme.sh" "$preview" >/dev/null 2>&1; }

# The engine renders every Wallpaper Engine type natively now — 2D scenes, web (CEF),
# video, and 3D model (.mdl) scenes — so no special handling per type is needed here;
# we just hand the item to the engine below. (The old three.js bake for 3D models is
# gone.) fallback() is only for non-WE wallpapers (plain images/videos).

# Already running for this monitor -> swap live.
if [ -S "$sock" ] && [ "$(send ping)" = pong ]; then
    [ "$(send "bg $monitor $dir")" = ok ] && { push_props; theme; exit 0; }
    fallback
    exit 0
fi

# Otherwise start a fresh engine for this monitor. Stop any stale wallpaper first.
pkill -f -- "--control-socket $sock" 2>/dev/null
rm -f "$sock"
for pid in $(pgrep -x mpvpaper); do
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$monitor" && kill "$pid" 2>/dev/null
done

args=(--control-socket "$sock" --screen-root "$monitor" --bg "$dir")
sc="$(we .wallpaperEngine.scaling.value)";  [ -n "$sc" ] && args+=(--scaling "$sc")
cl="$(we .wallpaperEngine.clamping.value)"; [ -n "$cl" ] && args+=(--clamp "$cl")
fp="$(we .wallpaperEngine.fps.value)";      [ -n "$fp" ] && args+=(--fps "$fp")
rs="$(we .wallpaperEngine.renderScale.value)"; [ -n "$rs" ] && args+=(--render-scale "$rs")
# Mute the wallpaper's own OUTPUT with volume 0, NOT --silent: --silent turns off
# audio *capture* (audioprocessing) too, which kills sound-reactive wallpapers
# (visualizers, reactive particles). Volume 0 silences output while reactivity
# keeps working off the system audio.
if [ "$(we .wallpaperEngine.mute.value)" = true ]; then
    args+=(--volume 0)
else
    vo="$(we .wallpaperEngine.volume.value)"; [ -n "$vo" ] && args+=(--volume "$vo")
fi
[ "$(we .wallpaperEngine.noAutomute.value)" = true ]        && args+=(--noautomute)
[ "$(we .wallpaperEngine.disableMouse.value)" = true ]      && args+=(--disable-mouse)
[ "$(we .wallpaperEngine.disableParallax.value)" = true ]   && args+=(--disable-parallax)
[ "$(we .wallpaperEngine.noFullscreenPause.value)" = true ] && args+=(--no-fullscreen-pause)
sp="$(we .wallpaper.playbackSpeed.value)"; [ -n "$sp" ] && [ "$sp" != 1 ] && args+=(--playback-speed "$sp")
ad="$(we .wallpaperEngine.audioDevice.value)"; [ -n "$ad" ] && args+=(--audio-device "$ad")

# Saved per-wallpaper property overrides: apply at launch via --set-property so
# they take effect on the initial load (the socket push_props below also handles
# live changes once running). This is what enables e.g. a web wallpaper's
# visualizer / background that ship disabled by default.
propconf="$daemon/config/properties/$id.conf"
if [ -f "$propconf" ]; then
    while IFS='=' read -r k v; do
        [ -n "$k" ] && args+=(--set-property "$k=$v")
    done < "$propconf"
fi

# Launch and confirm it stays up. CEF's GPU/offscreen init occasionally crashes
# on the first try (Wayland), so retry a couple times before giving up — a far
# better outcome than dropping a renderable wallpaper to a static preview.
started=false
for attempt in 1 2 3; do
    pkill -f -- "--control-socket $sock" 2>/dev/null
    rm -f "$sock"
    setsid "$bin" "${args[@]}" >/dev/null 2>&1 < /dev/null &
    disown
    for _ in $(seq 1 25); do [ -S "$sock" ] && break; sleep 0.2; done
    sleep 1
    if pgrep -f -- "--control-socket $sock" >/dev/null 2>&1; then
        started=true
        break
    fi
done

if [ "$started" = true ]; then
    # Property overrides were already applied at launch via --set-property above.
    # Do NOT re-push them over the socket here: that calls setProperty -> reloads
    # the wallpaper seconds after startup, which crashes CEF web wallpapers.
    theme
else
    fallback
fi
