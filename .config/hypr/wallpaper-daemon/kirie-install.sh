#!/bin/bash
#
# kirie-install.sh [--force]
#
# Installs the kirie wallpaper engine (https://github.com/UnhingedSoftware/kirie)
# into ~/.local/bin. Called by the installer, by `archeclipse update`, and by
# wallpaperengine.sh the first time a Workshop wallpaper is applied on a machine
# without an engine.
#
# KIRIE_VARIANT picks the build:
#   webview (default) — scene, video and web wallpapers, WebKit backed
#   cef               — web wallpapers on Chromium instead (~112 MB)
#   plain             — no web wallpapers, smallest download

set -uo pipefail

repo="UnhingedSoftware/kirie"
variant="${KIRIE_VARIANT:-webview}"
dest="$HOME/.local/bin"
force=""
[ "${1:-}" = "--force" ] && force=1

log() { printf 'kirie-install: %s\n' "$*"; }
# A bare invocation prints "kirie <version>" before complaining that no
# wallpaper was given; `--help` is the cheap liveness check (the CLI mirrors
# linux-wallpaperengine, which has no --version flag).
kirie_version() { "$1" 2>/dev/null | head -n1; }
die() { printf 'kirie-install: %s\n' "$*" >&2; exit 1; }

if [ -z "$force" ]; then
    for candidate in "$(command -v kirie 2>/dev/null)" "$dest/kirie"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        log "already installed: $candidate ($(kirie_version "$candidate"))"
        exit 0
    done
fi

[ "$(uname -m)" = "x86_64" ] || die "no prebuilt engine for $(uname -m); build from source: https://github.com/$repo"
command -v curl >/dev/null 2>&1 || die "curl is required"

# Asset names are stable, so /releases/latest/download avoids the API (and its
# rate limit) entirely.
base="https://github.com/$repo/releases/latest/download"
case "$variant" in
    webview) main_asset="kirie-web-webview-linux-x86_64"; host_asset="kirie-webviewhost-linux-x86_64" ;;
    cef)     main_asset="kirie-web-cef-linux-x86_64";     host_asset="" ;;
    plain)   main_asset="kirie-linux-x86_64";             host_asset="" ;;
    *)       die "unknown KIRIE_VARIANT '$variant' (webview, cef or plain)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { # fetch <asset> <target>
    log "downloading $1"
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$2" "$base/$1" ||
        die "download failed: $base/$1"
}

fetch "$main_asset" "$tmp/kirie"
[ -n "$host_asset" ] && fetch "$host_asset" "$tmp/kirie-webviewhost"
chmod +x "$tmp"/kirie*

# A truncated or rate-limited download still writes a file, so make the binary
# prove itself before it replaces a working engine.
"$tmp/kirie" --help >/dev/null 2>&1 || die "downloaded engine does not run; leaving the current one in place"

mkdir -p "$dest"
install -m 755 "$tmp/kirie" "$dest/kirie"
[ -n "$host_asset" ] && install -m 755 "$tmp/kirie-webviewhost" "$dest/kirie-webviewhost"

log "installed $(kirie_version "$dest/kirie") to $dest"

case ":$PATH:" in
    *":$dest:"*) ;;
    *) log "note: $dest is not in PATH (the wallpaper daemon finds it anyway)" ;;
esac

# Wallpaper Engine's own asset library is what scene wallpapers load their
# shaders and shared textures from; without it they render blank.
if ! find "$HOME/.local/share/Steam/steamapps/common/wallpaper_engine/assets" \
    -maxdepth 0 -type d >/dev/null 2>&1; then
    log "note: Wallpaper Engine (Steam) is not installed here — Workshop wallpapers need its assets to render"
fi

exit 0
