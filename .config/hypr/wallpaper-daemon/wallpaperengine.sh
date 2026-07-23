#!/bin/bash
#
# wallpaperengine.sh <monitor> <preview>
#
# Applies a Steam Wallpaper Engine workshop item using kirie
# (https://github.com/UnhingedSoftware/kirie). One persistent engine process
# runs per monitor, driven over a Unix control socket: changing wallpaper is
# a live in-place swap, a new process starts only when none is running.
# <preview> is the item's preview image at <workshop>/<id>/preview.*; the
# item folder (= the wallpaper) is its parent directory.
#
# If kirie is not installed yet, it is fetched once from the latest GitHub
# release by kirie-install.sh — a standalone executable, no build step.

hyprdir="$HOME/.config/hypr"
daemon="$hyprdir/wallpaper-daemon"
settings="$HOME/.config/ags/cache/settings/settings.json"

monitor="$1"
preview="$2"
[ -z "$monitor" ] || [ -z "$preview" ] && { echo "usage: wallpaperengine.sh <monitor> <preview>" >&2; exit 1; }

dir="$(dirname "$preview")"          # workshop item folder = the wallpaper
id="$(basename "$dir")"
sock="${XDG_RUNTIME_DIR:-/tmp}/lwe-$monitor.sock"

# Real rendered frames (one PNG per item), captured by asking the live engine
# to screenshot itself: the theme palette then matches what is actually on
# screen, and the frame doubles as a static fallback.
preview_cache="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaperengine/previews"

# Serialize per monitor: two concurrent applies (a switch racing the startup
# restore) would both pass the "nothing running" check and stack two engines
# on one output. Bounded wait so a stuck holder can never freeze switching.
# Every long-lived process spawned below MUST close fd 9 (9>&-) or it inherits
# the lock for its whole lifetime.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/lwe-$monitor.lock"
flock -w 15 9 || { echo "wallpaperengine.sh: lock timeout for $monitor" >&2; exit 1; }

bin="$(command -v kirie 2>/dev/null)"
[ -x "$bin" ] || bin="$HOME/.local/bin/kirie"
if [ ! -x "$bin" ]; then
    notify-send "Wallpaper Engine" "Installing the kirie engine…" 2>/dev/null
    "$daemon/kirie-install.sh" >/dev/null 2>&1
    bin="$HOME/.local/bin/kirie"
fi

we()   { jq -r "($1) // empty" "$settings" 2>/dev/null; }
send() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:$sock" 2>/dev/null; }

# Stage this wallpaper's saved property overrides BEFORE the swap: `stage`
# only records values (no rebuild), so the following `bg` builds the wallpaper
# once with every property already right. Fired concurrently — the engine
# drains all pending clients in one poll, so N properties cost one frame.
stage_props() {
    local f="$daemon/config/properties/$id.conf"
    [ -f "$f" ] || return
    while IFS='=' read -r k v; do
        [ -n "$k" ] && send "stage $k $v" &
    done < "$f"
    wait
}

# Engine missing or can't render this item -> show a static image instead.
# Prefer a previously captured rendered frame over the workshop preview.
fallback() {
    notify-send "Wallpaper Engine" "'$id' can't be rendered — showing a static preview." 2>/dev/null
    if [ -s "$preview_cache/$id.png" ]; then
        "$daemon/hyprpaper.sh" "$monitor" "$preview_cache/$id.png" 9>&-
        return
    fi
    case "${preview##*.}" in
        gif|webm|mp4|GIF|WEBM|MP4) "$daemon/mpvpaper.sh" "$monitor" "$preview" 9>&- ;;
        *)                         "$daemon/hyprpaper.sh" "$monitor" "$preview" 9>&- ;;
    esac
}

# Regenerate the desktop colour scheme from a real rendered frame — detached
# and debounced so it never delays the visible swap or holds the monitor lock.
# During rapid switching only the final wallpaper themes (marker guards it).
theme_async() {
    local marker="${XDG_RUNTIME_DIR:-/tmp}/lwe-theme-$monitor.target"
    printf '%s' "$id" > "$marker"
    setsid bash -c '
        marker=$1; want=$2; sock=$3; preview=$4; cache=$5; wal=$6
        sleep 0.4
        [ "$(cat "$marker" 2>/dev/null)" = "$want" ] || exit 0
        out="$cache/$want.png"
        if [ ! -s "$out" ]; then
            mkdir -p "$cache"
            printf "screenshot %s\n" "$out" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
            for _ in $(seq 1 40); do [ -s "$out" ] && break; sleep 0.1; done
        fi
        [ "$(cat "$marker" 2>/dev/null)" = "$want" ] || exit 0
        [ -s "$out" ] || out="$preview"
        "$wal" "$out" >/dev/null 2>&1
    ' _ "$marker" "$id" "$sock" "$preview" "$preview_cache" "$hyprdir/theme/scripts/wal-theme.sh" \
        >/dev/null 2>&1 9>&- < /dev/null &
    disown
}

[ -x "$bin" ] || { fallback; exit 0; }

# Push the current global settings to a live engine: it outlives launches
# (live swaps instead of relaunches), so launch-time flags go stale when
# settings change. All fired concurrently; every send no-ops on a dead
# socket. Absent settings keys leave the engine at its defaults.
push_settings() {
    local sc cl fp rs sp vo
    sp="$(we .wallpaper.playbackSpeed.value)";      [ -n "$sp" ] && send "speed $sp" &
    fp="$(we .wallpaperEngine.fps.value)";          [ -n "$fp" ] && send "set fps $fp" &
    rs="$(we .wallpaperEngine.renderScale.value)";  [ -n "$rs" ] && send "set renderscale $rs" &
    if [ "$(we .wallpaperEngine.mute.value)" = true ]; then
        send "mute 1" &
    else
        send "mute 0" &
        vo="$(we .wallpaperEngine.volume.value)";   [ -n "$vo" ] && send "volume $vo" &
    fi
    if [ "$(we .wallpaperEngine.disableParallax.value)" = true ]; then
        send "set disableparallax 1" &
    else
        send "set disableparallax 0" &
    fi
    sc="$(we .wallpaperEngine.scaling.value)";  [ -n "$sc" ] && send "scaling $monitor $sc" &
    cl="$(we .wallpaperEngine.clamping.value)"; [ -n "$cl" ] && send "clamp $monitor $cl" &
    wait
}

# Already running for this monitor -> swap live. The swap doubles as the
# liveness probe: a live engine answers "ok" or "error", a dead socket
# answers nothing. On "error" the engine is up but can't render this item ->
# static fallback; on no answer the socket is stale -> fresh start below.
if [ -S "$sock" ]; then
    push_settings
    stage_props
    resp="$(send "bg $monitor $dir")"
    if [ "$resp" = ok ]; then
        # On screen now; drop the lock before theming so back-to-back
        # switches don't serialise behind colour regeneration.
        exec 9>&-
        theme_async
        exit 0
    elif [ "$resp" = error ]; then
        fallback
        exit 0
    fi
fi

# Fresh start. Clear anything else that may be drawing on this output.
"$daemon/stop-engine.sh" "$monitor"
rm -f "$sock"
for pid in $(pgrep -x mpvpaper); do
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$monitor" && kill "$pid" 2>/dev/null
done

args=(--control-socket "$sock" --screen-root "$monitor" --bg "$dir")
sc="$(we .wallpaperEngine.scaling.value)";     [ -n "$sc" ] && args+=(--scaling "$sc")
cl="$(we .wallpaperEngine.clamping.value)";    [ -n "$cl" ] && args+=(--clamp "$cl")
fp="$(we .wallpaperEngine.fps.value)";         [ -n "$fp" ] && args+=(--fps "$fp")
rs="$(we .wallpaperEngine.renderScale.value)"; [ -n "$rs" ] && args+=(--render-scale "$rs")
# Mute via volume 0, NOT --silent: --silent also turns off audio *capture*,
# which kills sound-reactive wallpapers (visualizers, reactive particles).
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

# Saved per-wallpaper property overrides apply at launch so they take effect
# on the initial build (live changes go through `stage` + `bg` above).
propconf="$daemon/config/properties/$id.conf"
if [ -f "$propconf" ]; then
    while IFS='=' read -r k v; do
        [ -n "$k" ] && args+=(--set-property "$k=$v")
    done < "$propconf"
fi

# Small supervisor: relaunches the engine after an abnormal exit (driver
# hiccup, page crash), with backoff on rapid crash-loops. Clean exits and
# TERM/KILL are intentional stops — stop-engine.sh kills the engine process;
# the supervisor sees the clean code and ends with it.
#
# A watchdog covers the nastier failure: the compositor can close the layer
# surface (output disable, `hyprctl reload`, hotplug) leaving the engine
# alive but invisible. If the monitor is present and no wallpaperengine layer
# exists on it for a few checks, the engine is killed so the loop relaunches.
launch_supervised() {
    local log="${XDG_CACHE_HOME:-$HOME/.cache}/lwe-$monitor.log"
    mkdir -p "$(dirname "$log")"
    setsid bash -c '
        enginebin="$1"; shift
        log="$1"; shift
        monitor="$1"; shift
        crashes=0

        # True when the engine has a live layer on $monitor — and also true
        # (do not restart) when the monitor is gone or the probe cannot run:
        # the watchdog must never thrash against a missing output.
        engine_layer_ok() {
            command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
            local mons layers
            mons="$(hyprctl monitors -j 2>/dev/null)" || return 0
            printf "%s" "$mons" | jq -e --arg m "$monitor" "any(.[]; .name==\$m)" >/dev/null 2>&1 || return 0
            layers="$(hyprctl layers -j 2>/dev/null)" || return 0
            printf "%s" "$layers" | jq -e --arg m "$monitor" \
                "(.[\$m].levels // {}) | any(.[][]?; .namespace|test(\"wallpaperengine\"))" >/dev/null 2>&1
        }

        while :; do
            [ -f "$log" ] && [ "$(stat -c%s "$log" 2>/dev/null || echo 0)" -gt 1000000 ] && : > "$log"
            start=$(date +%s)
            "$enginebin" "$@" >>"$log" 2>&1 &
            epid=$!

            misses=0
            while kill -0 "$epid" 2>/dev/null; do
                sleep 15
                kill -0 "$epid" 2>/dev/null || break
                if engine_layer_ok; then
                    misses=0
                else
                    misses=$((misses+1))
                    if [ "$misses" -ge 3 ]; then
                        printf "%s engine alive but no layer on %s — restarting\n" "$(date -Is)" "$monitor" >>"$log"
                        kill "$epid" 2>/dev/null; sleep 2; kill -9 "$epid" 2>/dev/null
                        break
                    fi
                fi
            done
            wait "$epid"; rc=$?

            # A watchdog kill is an intentional restart, not an engine exit.
            if [ "$misses" -lt 3 ]; then
                case "$rc" in 0|129|130|137|143) exit 0 ;; esac
            fi

            ran=$(( $(date +%s) - start ))
            # Healthy uptime resets the counter: an occasional crash (e.g. a
            # surface loss when the monitor sleeps) is not a startup loop.
            if [ "$ran" -ge 60 ]; then crashes=0; else crashes=$((crashes+1)); fi
            printf "%s engine exit %s after %ss (crashes=%s)\n" "$(date -Is)" "$rc" "$ran" "$crashes" >>"$log"
            if [ "$crashes" -ge 5 ]; then
                notify-send -u critical "Wallpaper Engine" "Engine crash-looping (exit $rc) — backing off. Log: $log" 2>/dev/null
                sleep 30
                crashes=0
                continue
            fi
            notify-send "Wallpaper Engine" "Engine crashed (exit $rc) — restarting…" 2>/dev/null
            sleep 2
        done
    ' _ "$bin" "$log" "$monitor" "${args[@]}" >/dev/null 2>&1 9>&- < /dev/null &
    disown
}

# True when a kirie engine for this monitor is alive (matched by
# /proc/<pid>/exe, never by cmdline pattern — see stop-engine.sh).
engine_alive() {
    local p exe pid
    for p in /proc/[0-9]*/exe; do
        exe="$(readlink "$p" 2>/dev/null)" || continue
        [ "$(basename "$exe")" = kirie ] || continue
        pid="${p#/proc/}"; pid="${pid%/exe}"
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null |
            grep -q -- "--screen-root $monitor " && return 0
    done
    return 1
}

# Start and confirm it comes up; one retry covers a transient GPU/compositor
# hiccup at launch.
started=false
for attempt in 1 2; do
    "$daemon/stop-engine.sh" "$monitor"
    rm -f "$sock"
    launch_supervised
    for _ in $(seq 1 25); do [ -S "$sock" ] && break; sleep 0.2; done
    sleep 1
    if engine_alive; then
        started=true
        break
    fi
done

if [ "$started" = true ]; then
    theme_async
else
    fallback
fi
