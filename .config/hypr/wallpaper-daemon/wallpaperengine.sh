#!/bin/bash
#
# wallpaperengine.sh — Steam Workshop "Wallpaper Engine" wallpapers, rendered by
# kirie (a native Linux Wallpaper Engine implementation).
#
# One long-lived engine process per monitor is driven over a Unix control
# socket, so changing wallpaper is a live swap instead of a relaunch.
#
#   wallpaperengine.sh <monitor> <item>          shorthand for: apply
#   wallpaperengine.sh apply <monitor> <item>    <item> = workshop folder or its preview file
#   wallpaperengine.sh stop <monitor>|all
#   wallpaperengine.sh restart [monitor]         re-apply with fresh launch flags
#   wallpaperengine.sh ctl <command...>          live command to every running engine
#   wallpaperengine.sh gpus                      "<value><TAB><label>" per renderable GPU
#   wallpaperengine.sh audio-devices             "<value><TAB><label>" per audio output
#   wallpaperengine.sh properties current|list|set|reset <monitor> [key value]

self="$(readlink -f "$0")"
daemon="$(dirname "$self")"
hyprdir="$(dirname "$daemon")"
settings="$HOME/.config/ags/cache/settings/settings.json"
props_dir="$daemon/config/properties"

# Per-monitor runtime state: <monitor>.sock (engine control socket), .lock
# (apply serialisation) and .current (the applied item, so restart/properties
# know what is on screen without re-resolving the wallpaper configuration).
rt="${XDG_RUNTIME_DIR:-/tmp}/wallpaperengine"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaperengine"
# Real rendered frames, one PNG per item: both the theme colour source and the
# static fallback should look like the wallpaper, not like the workshop art.
frames="$cache/frames"

usage() { sed -n '3,16p' "$self" >&2; exit 1; }

setting() { jq -r "($1) // empty" "$settings" 2>/dev/null; }
send()    { printf '%s\n' "$2" | timeout 2 socat - "UNIX-CONNECT:$1" 2>/dev/null; }

# kirie only: the C++ linux-wallpaperengine has no control socket, so none of
# the live-swap behaviour below would work against it.
engine_bin() {
    command -v kirie 2>/dev/null && return 0
    [ -x "$HOME/.local/bin/kirie" ] && { printf '%s\n' "$HOME/.local/bin/kirie"; return 0; }
    return 1
}

# Stop whatever matches $1 (a socket path, or the runtime directory for "all").
# Engine and supervisor both carry the socket path in their argv and both must
# go: the supervisor would restart an engine killed on its own, and the engine
# would outlive a supervisor killed on its own. Signalling the process group as
# well as the pid ("-$p") is what makes that atomic — setsid put the pair in one
# session, so the group kill also interrupts the supervisor mid-poll instead of
# leaving it around until its next wakeup; the plain pid covers an engine whose
# supervisor is already gone.
#
# Then wait for the exit before the socket file is unlinked: a lingering engine
# keeps listening on the socket inode after the file is gone, and every later
# control command silently fails against the orphan. Takes no lock on purpose —
# the static backends call this while apply() holds the per-monitor lock.
stop_match() {
    local p
    for p in $(pgrep -f -- "$1" 2>/dev/null); do kill -- "$p" "-$p" 2>/dev/null; done
    for _ in $(seq 1 30); do
        pgrep -f -- "$1" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    for p in $(pgrep -f -- "$1" 2>/dev/null); do kill -9 -- "$p" "-$p" 2>/dev/null; done
}

cmd_stop() {
    [ -n "$1" ] || usage
    # "<monitor>.sock" can never be a prefix of another monitor socket, so this
    # stops HDMI-A-1 without touching HDMI-A-10.
    case "$1" in
        all) stop_match "$rt/"; rm -f "$rt"/*.sock "$rt"/*.current ;;
        *)   stop_match "$rt/$1.sock"; rm -f "$rt/$1.sock" "$rt/$1.current" ;;
    esac
}

# --- apply ------------------------------------------------------------------
# monitor/dir/id/sock stay global so the helpers below can read them.

# Stage this item's saved property overrides BEFORE the swap. `stage` only
# records a value — no live effect, no rebuild — so the following `bg` builds
# the wallpaper once with every override already in place, instead of building
# it with defaults and rebuilding for each property pushed afterwards. Fired
# concurrently: the engine drains all pending clients in one poll, so N
# properties cost one render frame rather than N.
stage_props() {
    local k v
    [ -f "$props_dir/$id.conf" ] || return 0
    while IFS='=' read -r k v; do
        [ -n "$k" ] && send "$sock" "stage $k $v" >/dev/null &
    done < "$props_dir/$id.conf"
    wait
}

item_preview() {
    local f
    for f in "$dir"/preview.*; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done
}

# The item cannot be rendered (unsupported, or the engine would not start): show
# a still image rather than a blank desktop. A cached rendered frame beats the
# workshop preview art. The static backends stop the engine themselves, and 9>&-
# keeps the long-lived mpvpaper from inheriting the per-monitor lock.
fallback() {
    local p
    notify-send "Wallpaper Engine" "Cannot render '$id' — showing a still image." 2>/dev/null
    p="$frames/$id.png"
    [ -s "$p" ] || p="$(item_preview)"
    [ -n "$p" ] || return 0
    case "$(printf '%s' "${p##*.}" | tr '[:upper:]' '[:lower:]')" in
        gif|mp4|webm) "$daemon/mpvpaper.sh"  "$monitor" "$p" 9>&- ;;
        *)            "$daemon/hyprpaper.sh" "$monitor" "$p" 9>&- ;;
    esac
}

# Regenerate the desktop palette from a REAL rendered frame (the engine
# screenshots itself) instead of from the workshop art, so the colours match
# what is actually on screen. Detached and debounced: a burst of workspace
# switches only themes the wallpaper that stays, and colour regeneration never
# delays the visible swap nor holds the per-monitor lock.
theme_async() {
    setsid bash -c '
        state=$1; want=$2; sock=$3; out=$4; art=$5; wal=$6
        sleep 0.4
        [ "$(cat "$state" 2>/dev/null)" = "$want" ] || exit 0
        if [ ! -s "$out" ]; then
            mkdir -p "${out%/*}"
            printf "screenshot %s\n" "$out" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
            for _ in $(seq 1 40); do [ -s "$out" ] && break; sleep 0.1; done
        fi
        # Recolour only while this wallpaper is still the one on screen.
        [ "$(cat "$state" 2>/dev/null)" = "$want" ] || exit 0
        [ -s "$out" ] || out=$art
        [ -n "$out" ] && [ -s "$out" ] && "$wal" "$out" >/dev/null 2>&1
    ' _ "$rt/$monitor.current" "$dir" "$sock" "$frames/$id.png" "$(item_preview)" \
        "$hyprdir/theme/scripts/wal-theme.sh" >/dev/null 2>&1 9>&- </dev/null &
    disown
}

# Keep the engine alive: an abnormal exit (driver hiccup, GPU reset, CEF
# teardown) relaunches it, with a backoff so a hard crash loop does not spin.
# Clean exits and TERM/KILL are intentional stops — that is how cmd_stop stops
# the pair. The watchdog covers the failure no exit code can see: the compositor
# can drop the engine layer surface (output disable, hyprctl reload, hotplug)
# and leave a live process rendering nothing, so poll Hyprland and relaunch when
# the monitor is there but the engine has no layer on it.
launch() {
    mkdir -p "$cache"
    setsid bash -c '
        bin=$1; log=$2; monitor=$3; sock=$4; shift 4
        crashes=0
        # True when the engine owns a layer on $monitor. Also true when the
        # monitor is gone or hyprctl/jq are missing: there is nothing to render
        # on, so the watchdog must not thrash on a probe it cannot trust.
        layer_ok() {
            command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
            hyprctl monitors -j 2>/dev/null |
                jq -e --arg m "$monitor" "any(.[]; .name==\$m)" >/dev/null 2>&1 || return 0
            hyprctl layers -j 2>/dev/null | jq -e --arg m "$monitor" \
                "(.[\$m].levels // {}) | any(.[][]?; .namespace|test(\"wallpaperengine\"))" \
                >/dev/null 2>&1
        }
        while :; do
            [ "$(stat -c%s "$log" 2>/dev/null || echo 0)" -gt 1000000 ] && : > "$log"
            # Drop the dead engine socket, or the relaunch cannot bind its own.
            rm -f "$sock"
            start=$(date +%s)
            "$bin" "$@" >>"$log" 2>&1 &
            epid=$!
            misses=0
            while kill -0 "$epid" 2>/dev/null; do
                sleep 5
                kill -0 "$epid" 2>/dev/null || break
                if layer_ok; then misses=0; else misses=$((misses+1)); fi
                if [ "$misses" -ge 3 ]; then
                    printf "%s no layer on %s — restarting\n" "$(date -Is)" "$monitor" >>"$log"
                    kill "$epid" 2>/dev/null; sleep 2; kill -9 "$epid" 2>/dev/null
                    break
                fi
            done
            wait "$epid"; rc=$?
            # A watchdog kill is a restart, not a stop: skip the intentional-exit test.
            [ "$misses" -lt 3 ] && case "$rc" in 0|129|130|137|143) exit 0 ;; esac
            # Only a short run counts towards the crash loop; an engine that ran
            # for an hour and then died is not a startup failure.
            [ $(( $(date +%s) - start )) -ge 60 ] && crashes=0 || crashes=$((crashes+1))
            printf "%s exit %s (crashes=%s)\n" "$(date -Is)" "$rc" "$crashes" >>"$log"
            if [ "$crashes" -ge 5 ]; then
                notify-send -u critical "Wallpaper Engine" \
                    "Engine keeps crashing — backing off. Log: $log" 2>/dev/null
                crashes=0; sleep 30
            else
                sleep 2
            fi
        done
    ' _ "$bin" "$cache/$monitor.log" "$monitor" "$sock" "${args[@]}" >/dev/null 2>&1 9>&- </dev/null &
    disown
}

cmd_apply() {
    local bin resp v k
    monitor="$1"
    [ -n "$monitor" ] && [ -n "$2" ] || usage
    # The item is the workshop folder; callers pass either it or its preview file.
    dir="${2%/}"; [ -d "$dir" ] || dir="$(dirname "$dir")"
    id="${dir##*/}"
    sock="$rt/$monitor.sock"
    mkdir -p "$rt"

    # Serialise per monitor: two concurrent applies (a manual switch racing the
    # shell startup restore) would both see "no engine running" and stack two
    # engines on one output, fighting over the same socket. The loser waits and
    # then takes the live-swap path instead. Bounded, so a stuck holder cannot
    # freeze wallpaper switching outright. Everything long-lived spawned below
    # closes fd 9 (9>&-) — inheriting the lock would hold it for that lifetime.
    exec 9>"$rt/$monitor.lock"
    flock -w 15 9 || { echo "wallpaperengine: lock timeout for $monitor" >&2; return 1; }

    bin="$(engine_bin)" || {
        notify-send -u critical "Wallpaper Engine" "kirie is not installed" 2>/dev/null
        fallback; return 1
    }

    # Fast path: an engine is already up for this monitor, so swap over the
    # socket (milliseconds) instead of relaunching. The swap doubles as the
    # liveness probe, saving a round trip: a live engine answers ok or error, a
    # stale socket answers nothing and falls through to a fresh start.
    if [ -S "$sock" ]; then
        stage_props
        resp="$(send "$sock" "bg $monitor $dir")"
        case "$resp" in
            ok) printf '%s\n' "$dir" > "$rt/$monitor.current"
                # On screen already: drop the lock before theming so back-to-back
                # switches do not serialise behind colour regeneration.
                exec 9>&-
                theme_async
                return 0 ;;
            error) fallback; return 0 ;;   # engine is up but cannot render this item
        esac
    fi

    args=(--control-socket "$sock" --screen-root "$monitor" --bg "$dir")
    v="$(setting .wallpaperEngine.scaling.value)";     [ -n "$v" ] && args+=(--scaling "$v")
    v="$(setting .wallpaperEngine.clamping.value)";    [ -n "$v" ] && args+=(--clamp "$v")
    v="$(setting .wallpaperEngine.fps.value)";         [ -n "$v" ] && args+=(--fps "$v")
    v="$(setting .wallpaperEngine.renderScale.value)"; [ -n "$v" ] && args+=(--render-scale "$v")
    v="$(setting .wallpaperEngine.audioDevice.value)"; [ -n "$v" ] && args+=(--audio-device "$v")
    # Which GPU renders. kirie resolves the token to a Vulkan ICD and pins the
    # loader to it, which also roughly halves engine memory: the loader
    # otherwise keeps every installed vendor stack resident. "auto" leaves it
    # alone. The tokens come from `gpus` below, so nothing vendor-specific
    # lives here.
    v="$(setting .wallpaperEngine.gpu.value)"
    [ -n "$v" ] && [ "$v" != auto ] && args+=(--gpu "$v")
    # Mute the wallpaper OUTPUT with volume 0, never with --silent: --silent also
    # turns off audio capture, which kills sound-reactive wallpapers.
    if [ "$(setting .wallpaperEngine.mute.value)" = true ]; then
        args+=(--volume 0)
    else
        v="$(setting .wallpaperEngine.volume.value)"; [ -n "$v" ] && args+=(--volume "$v")
    fi
    [ "$(setting .wallpaperEngine.noAutomute.value)" = true ]        && args+=(--noautomute)
    [ "$(setting .wallpaperEngine.disableMouse.value)" = true ]      && args+=(--disable-mouse)
    [ "$(setting .wallpaperEngine.disableParallax.value)" = true ]   && args+=(--disable-parallax)
    [ "$(setting .wallpaperEngine.noFullscreenPause.value)" = true ] && args+=(--no-fullscreen-pause)
    # Never shade more pixels than the monitor can show: a scene renders at the
    # size its author chose, and anything above the output resolution is drawn
    # only to be discarded by the final blit.
    [ "$(setting .wallpaperEngine.fitRenderToOutput.value)" = true ] && args+=(--fit-render-to-output)
    # Hand the wallpaper's memory back while a fullscreen app covers it; it is
    # rebuilt from the engine's cache when the output is visible again.
    v="$(setting .wallpaperEngine.releaseHiddenAfter.value)"
    [ -n "$v" ] && [ "$v" != 0 ] && args+=(--release-hidden-after "$v")
    # Overrides at launch, so the very first build already has them. Do not
    # re-push them over the socket right after startup: that reloads the
    # wallpaper seconds in, which can take web wallpapers down.
    if [ -f "$props_dir/$id.conf" ]; then
        while IFS='=' read -r k v; do
            [ -n "$k" ] && args+=(--set-property "$k=$v")
        done < "$props_dir/$id.conf"
    fi

    stop_match "$sock"; rm -f "$sock"
    launch
    # The supervisor retries a failed start by itself, so wait for the socket
    # long enough to cover one relaunch before calling it dead.
    for _ in $(seq 1 40); do [ -S "$sock" ] && break; sleep 0.25; done
    if [ -S "$sock" ] && pgrep -f -- "$sock" >/dev/null 2>&1; then
        printf '%s\n' "$dir" > "$rt/$monitor.current"
        exec 9>&-
        theme_async
    else
        stop_match "$sock"; rm -f "$sock"
        fallback
    fi
}

# --- other subcommands ------------------------------------------------------

# Re-apply the wallpaper on screen with fresh launch flags, for settings the
# running engine cannot change live (the audio capture device is bound once at
# startup, the GPU pin at ICD load). Without an argument: every live monitor.
cmd_restart() {
    local f m d
    if [ -n "$1" ]; then set -- "$rt/$1.current"; else set -- "$rt"/*.current; fi
    for f in "$@"; do
        [ -f "$f" ] || continue
        m="${f##*/}"; m="${m%.current}"
        d="$(cat "$f")"
        [ -n "$d" ] || continue
        cmd_stop "$m"
        "$self" apply "$m" "$d"
    done
}

# Broadcast a live control command to every running engine so option, property
# and volume changes apply without a restart. Screen-scoped commands get the
# monitor inserted. Exits non-zero with a reason on stdout when nothing accepted
# the command, so the caller can fall back to a restart instead of failing
# silently against a dead or orphaned socket.
cmd_ctl() {
    local sock m cmd resp last="" found=0 delivered=0
    [ -n "$1" ] || return 0
    for sock in "$rt"/*.sock; do
        [ -S "$sock" ] || continue
        found=1
        m="${sock##*/}"; m="${m%.sock}"
        case "$1" in
            scaling|clamp|property) cmd="$1 $m ${*:2}" ;;
            *)                      cmd="$*" ;;
        esac
        resp="$(send "$sock" "$cmd" | tr -d '\r\n')"
        last="$resp"
        case "$resp" in ""|error*|"unknown command"*) continue ;; esac
        delivered=$((delivered + 1))
    done
    [ "$found" = 1 ] || { echo "no engine running"; return 1; }
    [ "$delivered" -gt 0 ] || { echo "${last:-rejected}"; return 1; }
}

# Name the hardware a driver actually drives ("NVIDIA GeForce RTX 4080") rather
# than a bare vendor: find the DRM card bound to this driver, resolve its PCI
# address from the device link and ask lspci for the model. Deliberately does
# NOT guess integrated versus discrete — every cheap signal for that is wrong
# somewhere, and a confidently mislabelled GPU is worse than an honest vendor
# name; the model tells the user which card it is anyway.
gpu_model() {
    local path addr name
    command -v lspci >/dev/null 2>&1 || return 0
    for path in /sys/class/drm/card[0-9]*; do
        [ "$(sed -n 's/^DRIVER=//p' "$path/device/uevent" 2>/dev/null)" = "$1" ] || continue
        addr="$(basename "$(readlink -f "$path/device" 2>/dev/null)")"
        case "$addr" in *:*:*.*) ;; *) return 0 ;; esac   # only usable if PCI
        # lspci writes the model two ways:
        #   "NVIDIA Corporation AD103 [GeForce RTX 4080]"    -> trailing bracket
        #   "Advanced Micro Devices, Inc. [AMD/ATI] Raphael" -> vendor bracket first
        # so taking the first bracket yields the useless alias "AMD/ATI". Strip
        # the trailing " (rev xx)" first: it hides the closing bracket.
        name="$(lspci -s "${addr#0000:}" 2>/dev/null | head -1 |
            sed -e 's/^[^:]*: //' -e 's/ (rev [^)]*)$//')"
        case "$name" in
            *\])  name="${name##*[}"; name="${name%%]*}" ;;
            *\]*) name="${name##*] }" ;;
        esac
        printf '%s' "$name"
        return 0
    done
}

# GPUs this machine can render on, one "<token><TAB><label>" per line, for the
# Render GPU setting; the token is what kirie's --gpu resolves to a Vulkan ICD.
# The list is whatever Vulkan drivers are installed, cross-referenced with the
# DRM devices the kernel reports — no vendor, PCI address or ICD path is
# hardcoded, so an Intel laptop, a single-GPU desktop and a dual-GPU box each
# get the choices that make sense for them.
cmd_gpus() {
    local d manifest name token label model seen=""
    # Loader default: every ICD stays loaded. Correct everywhere, so it leads.
    printf 'auto\tAutomatic (no pinning)\n'
    for d in /usr/share/vulkan/icd.d /usr/local/share/vulkan/icd.d /etc/vulkan/icd.d; do
        for manifest in "$d"/*.json; do
            [ -e "$manifest" ] || continue
            name="${manifest##*/}"
            model=""
            case "$name" in
                nvidia_icd*)          token=nvidia;  label=NVIDIA;  model="$(gpu_model nvidia)" ;;
                radeon_icd*|amd_icd*) token=amd;     label=AMD;     model="$(gpu_model amdgpu)" ;;
                intel_icd*)           token=intel;   label=Intel
                                      model="$(gpu_model i915)"
                                      [ -n "$model" ] || model="$(gpu_model xe)" ;;
                intel_hasvk*)         continue ;;  # legacy driver for hardware intel_icd already lists
                nouveau_icd*)         token=nouveau; label=Nouveau; model="$(gpu_model nouveau)" ;;
                lvp_icd*)             token=lvp;     label="Software (llvmpipe)" ;;
                virtio_icd*)          token=virtio;  label="VirtIO (virtual)" ;;
                powervr*|broadcom*|freedreno*|panfrost*)
                                      token="${name%%_*}"; label="$token" ;;
                *)                    continue ;;
            esac
            case " $seen " in *" $token "*) continue ;; esac
            seen="$seen $token"
            printf '%s\t%s\n' "$token" "$label${model:+ $model}"
        done
    done
}

# Audio outputs for sound-reactive wallpapers, one "<value><TAB><label>" per
# line. Wallpaper Engine reacts to a sink monitor source, hence the suffix.
cmd_audio_devices() {
    pactl list sinks 2>/dev/null | awk -F': ' '
        /^[[:space:]]*Name:/        { name = $2 }
        /^[[:space:]]*Description:/ { if (name != "") { print name ".monitor" "\t" $2; name = "" } }
    '
}

# Per-wallpaper customisable properties (the Wallpaper Engine "selectors": bool
# / slider / color / combo / textinput). Overrides live one key=value per line
# in config/properties/<id>.conf, and become --set-property at launch or `stage`
# before a live swap. Everything is addressed by monitor so no caller needs to
# know where the Steam workshop is installed.
#
#   properties current <monitor>          id of the applied item, empty if none
#   properties list    <monitor>          its properties as JSON, overrides applied
#   properties set     <monitor> <k> <v>  upsert one override
#   properties reset   <monitor>          drop all overrides and reload the monitor
cmd_properties() {
    local action="$1" monitor="$2" dir id f ov k v
    dir="$(cat "$rt/$monitor.current" 2>/dev/null)"
    id="${dir##*/}"
    f="$props_dir/$id.conf"
    [ -n "$id" ] || { [ "$action" = list ] && echo "[]"; return 0; }

    case "$action" in
        current) printf '%s\n' "$id" ;;
        list)
            [ -f "$dir/project.json" ] || { echo "[]"; return 0; }
            # Fold the flat overrides into a JSON object so jq can apply them
            # over the wallpaper's declared defaults in a single pass.
            ov="{}"
            if [ -f "$f" ]; then
                while IFS='=' read -r k v; do
                    [ -n "$k" ] && ov="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$ov")"
                done < "$f"
            fi
            jq -c --argjson ov "$ov" '
                (.general.properties // {}) | to_entries
                | map({ key: .key, type: (.value.type // "unknown"),
                        text: (.value.text // .key), value: (.value.value // null),
                        options: (.value.options // null), min: (.value.min // null),
                        max: (.value.max // null), step: (.value.step // null),
                        order: (.value.order // 0) })
                | sort_by(.order)
                | map(if $ov[.key] != null then .value = $ov[.key] else . end)
            ' "$dir/project.json" 2>/dev/null || echo "[]"
            ;;
        set)
            [ -n "$3" ] || return 1
            mkdir -p "$props_dir"
            # Rewrite rather than sed in place: property values are free text and
            # would otherwise have to be escaped for the sed expression.
            { grep -v "^$3=" "$f" 2>/dev/null; printf '%s=%s\n' "$3" "$4"; } > "$f.new" &&
                mv "$f.new" "$f"
            ;;
        reset)
            # Clearing overrides needs a reload: the engine has no way to go back
            # to a value it was never told.
            rm -f "$f"
            cmd_restart "$monitor"
            ;;
        *) usage ;;
    esac
}

case "$1" in
    apply)         shift; cmd_apply "$@" ;;
    stop)          cmd_stop "$2" ;;
    restart)       cmd_restart "$2" ;;
    ctl)           shift; cmd_ctl "$@" ;;
    gpus)          cmd_gpus ;;
    audio-devices) cmd_audio_devices ;;
    properties)    shift; cmd_properties "$@" ;;
    # Two bare arguments are an apply: every wallpaper backend in this directory
    # is called as "<script> <monitor> <wallpaper>".
    *) if [ $# -eq 2 ]; then cmd_apply "$@"; else usage; fi ;;
esac
