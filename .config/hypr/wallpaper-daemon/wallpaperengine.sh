#!/bin/bash
# wallpaperengine.sh <monitor> <preview>
#
# Applies a Wallpaper Engine item with kirie.

hyprdir="$HOME/.config/hypr"
daemon="$hyprdir/wallpaper-daemon"
settings="$HOME/.config/ags/cache/settings/settings.json"

monitor="$1"
preview="$2"
[ -z "$monitor" ] || [ -z "$preview" ] && { echo "usage: wallpaperengine.sh <monitor> <preview>" >&2; exit 1; }

dir="$(dirname "$preview")"          # workshop item folder = the wallpaper
id="$(basename "$dir")"
# one engine, all monitors
sock="${XDG_RUNTIME_DIR:-/tmp}/lwe.sock"

# rendered-frame cache
preview_cache="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaperengine/previews"

# one apply at a time; engine must not inherit fd 9
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/lwe.lock"
flock -w 15 9 || { echo "wallpaperengine.sh: lock timeout for $monitor" >&2; exit 1; }

# prefer kirie
bin="$(command -v kirie 2>/dev/null)"
[ -x "$bin" ] || bin="$HOME/.local/bin/kirie"
[ -x "$bin" ] || bin="$HOME/kirie/target/release/kirie"
[ -x "$bin" ] || bin="$HOME/linux-wallpaperengine/build/output/linux-wallpaperengine"
[ -x "$bin" ] || bin="$(command -v linux-wallpaperengine)" || {
    notify-send -u critical "Wallpaper Engine" "no wallpaper engine (kirie / linux-wallpaperengine) installed" 2>/dev/null; exit 1; }

we()   { jq -r "($1) // empty" "$settings" 2>/dev/null; }
send() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:$sock" 2>/dev/null; }

# stage props, so bg builds once
stage_props() {
    local f="$daemon/config/properties/$id.conf"
    [ -f "$f" ] || return
    while IFS='=' read -r k v; do
        [ -n "$k" ] && send "stage $k $v" &
    done < "$f"
    wait
}

# static fallback
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

# theme from a real frame; detached + debounced
theme_async() {
    local marker="${XDG_RUNTIME_DIR:-/tmp}/lwe-theme-$monitor.target"
    printf '%s' "$id" > "$marker"
    setsid bash -c '
        marker=$1; want=$2; sock=$3; preview=$4; cache=$5; wal=$6
        # debounce
        sleep 0.4
        [ "$(cat "$marker" 2>/dev/null)" = "$want" ] || exit 0
        out="$cache/$want.png"
        if [ ! -s "$out" ]; then
            mkdir -p "$cache"
            printf "screenshot %s\n" "$out" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
            for _ in $(seq 1 40); do [ -s "$out" ] && break; sleep 0.1; done
        fi
        # still on screen?
        [ "$(cat "$marker" 2>/dev/null)" = "$want" ] || exit 0
        [ -s "$out" ] || out="$preview"
        "$wal" "$out" >/dev/null 2>&1
    ' _ "$marker" "$id" "$sock" "$preview" "$preview_cache" "$hyprdir/theme/scripts/wal-theme.sh" \
        >/dev/null 2>&1 9>&- < /dev/null &
    disown
}


# live swap; dead socket falls through
engine_owns_monitor() {
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

if [ -S "$sock" ] && engine_owns_monitor; then
    # push live settings
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
    push_settings
    # stage, then swap
    stage_props
    resp="$(send "bg $monitor $dir")"
    if [ "$resp" = ok ]; then
        # unlock before theming
        exec 9>&-
        theme_async
        exit 0
    elif [ "$resp" = error ]; then
        fallback
        exit 0
    fi
    # engine gone -> fresh start
fi

# stop and wait, or the socket lingers
stop_engine () {
    pgrep -f -- "--control-socket $sock" >/dev/null 2>&1 || return 0
    pkill -f -- "--control-socket $sock" 2>/dev/null
    for _ in $(seq 1 30); do
        pgrep -f -- "--control-socket $sock" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    pkill -9 -f -- "--control-socket $sock" 2>/dev/null
    sleep 0.2
}

# fresh start
stop_engine
rm -f "$sock"
for pid in $(pgrep -x mpvpaper); do
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$monitor" && kill "$pid" 2>/dev/null
done

# every monitor, one process
args=(--control-socket "$sock")
while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ "$m" = "$monitor" ]; then
        mdir="$dir"
    else
        mprev="$("$daemon/apply-current.sh" "$m" --print 2>/dev/null)"
        [ -n "$mprev" ] || continue
        mdir="$(dirname "$mprev")"
    fi
    [ -f "$mdir/project.json" ] || continue
    args+=(--screen-root "$m" --bg "$mdir")
done < <(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null)
sc="$(we .wallpaperEngine.scaling.value)";  [ -n "$sc" ] && args+=(--scaling "$sc")
cl="$(we .wallpaperEngine.clamping.value)"; [ -n "$cl" ] && args+=(--clamp "$cl")
fp="$(we .wallpaperEngine.fps.value)";      [ -n "$fp" ] && args+=(--fps "$fp")
rs="$(we .wallpaperEngine.renderScale.value)"; [ -n "$rs" ] && args+=(--render-scale "$rs")
# render GPU (pins one ICD)
want_gpu="$(we .wallpaperEngine.gpu.value)"
[ -n "$want_gpu" ] && [ "$want_gpu" != auto ] && args+=(--gpu "$want_gpu")
# cap render at output size
args+=(--fit-render-to-output)
# free memory while hidden
args+=(--release-hidden-after 15)
# volume 0, not --silent: keeps reactivity
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

# saved overrides, applied at launch
propconf="$daemon/config/properties/$id.conf"
if [ -f "$propconf" ]; then
    while IFS='=' read -r k v; do
        [ -n "$k" ] && args+=(--set-property "$k=$v")
    done < "$propconf"
fi

# supervisor: relaunch on crash, watchdog for a lost layer
launch_supervised() {
    local log="${XDG_CACHE_HOME:-$HOME/.cache}/lwe.log"
    mkdir -p "$(dirname "$log")"
    setsid bash -c '
        enginebin="$1"; shift
        log="$1"; shift
        monitor="$1"; shift
        crashes=0

        # engine has a layer? absent monitor counts as ok
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
            # cap log size
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

            # watchdog kill -> relaunch
            if [ "$misses" -lt 3 ]; then
                case "$rc" in 0|129|130|137|143) exit 0 ;; esac
            fi

            ran=$(( $(date +%s) - start ))
            # healthy uptime resets the counter
            if [ "$ran" -ge 60 ]; then crashes=0; else crashes=$((crashes+1)); fi
            printf "%s engine exit %s after %ss (crashes=%s)\n" "$(date -Is)" "$rc" "$ran" "$crashes" >>"$log"
            if [ "$crashes" -ge 5 ]; then
                # back off, keep trying
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

# retry: CEF init can fail once
started=false
for attempt in 1 2 3; do
    stop_engine
    rm -f "$sock"
    launch_supervised
    for _ in $(seq 1 25); do [ -S "$sock" ] && break; sleep 0.2; done
    sleep 1
    if pgrep -f -- "--control-socket $sock" >/dev/null 2>&1; then
        started=true
        break
    fi
done

if [ "$started" = true ]; then
    # already applied at launch; re-pushing reloads
    theme_async
else
    fallback
fi
