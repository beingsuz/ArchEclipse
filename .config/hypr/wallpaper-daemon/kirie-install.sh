#!/bin/bash
#
# kirie-install.sh [plain|webview|cef]
#
# Installs kirie (the Rust Wallpaper Engine for Linux) into ~/.local/bin/kirie
# by downloading a standalone executable straight from the latest GitHub
# release — no compiler, no build, no repo clone.
#
#   plain    scenes + video + images, smallest
#   webview  + web wallpapers via the system webkit2gtk-4.1, presented
#            natively on the compositor's background layer by the
#            kirie-webviewhost helper (downloaded alongside; default).
#            Needs webkit2gtk-4.1 + libsoup3 + gtk-layer-shell installed.
#   cef      + full web wallpaper support with bundled Chromium
#            (self-extracting single file, ~110 MB, zero system deps)

set -euo pipefail

repo="UnhingedSoftware/kirie"
variant="${1:-webview}"
case "$variant" in
    plain)   asset="kirie-linux-x86_64" ;;
    webview) asset="kirie-web-webview-linux-x86_64" ;;
    cef)     asset="kirie-web-cef-linux-x86_64" ;;
    *) echo "usage: kirie-install.sh [plain|webview|cef]" >&2; exit 1 ;;
esac

bindir="$HOME/.local/bin"
mkdir -p "$bindir"

fetch() { # fetch <asset> <dest-name>
    local tmp
    tmp="$(mktemp "$bindir/.kirie.XXXXXX")"
    echo "downloading $1 ..."
    if ! curl -fL --retry 3 --progress-bar -o "$tmp" \
        "https://github.com/$repo/releases/latest/download/$1"; then
        rm -f "$tmp"; return 1
    fi
    chmod +x "$tmp"
    mv -f "$tmp" "$bindir/$2"
}

fetch "$asset" kirie
# The webview engine drives web wallpapers through the kirie-webviewhost
# helper, which must sit beside it.
if [ "$variant" = webview ]; then
    fetch kirie-webviewhost-linux-x86_64 kirie-webviewhost
    if ! ldconfig -p 2>/dev/null | grep -q libwebkit2gtk-4.1; then
        echo "note: webkit2gtk-4.1 not found — install it (Arch: pacman -S webkit2gtk-4.1 libsoup3 gtk-layer-shell)" >&2
    fi
fi

echo "installed: $bindir/kirie ($variant)"
