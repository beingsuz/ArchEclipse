#!/usr/bin/env python3
"""Install kirie — the prebuilt Rust Wallpaper Engine renderer behind the WE integration.

kirie (https://github.com/beingsuz/kirie) is a from-scratch Rust renderer that is drop-in
compatible with linux-wallpaperengine's CLI and control socket, so the daemon
(``~/.config/hypr/wallpaper-daemon/wallpaperengine.sh``) drives it unchanged. Unlike the old
C++ fork this ships **prebuilt release binaries**, so there is nothing to compile — the install
just downloads the right variant and unpacks it to::

    ~/kirie-bin/kirie          (+ a ~/.local/bin/kirie symlink for PATH)

Web wallpapers need a browser backend; there are two release variants:

    web-webview  — light; renders through the system ``webkit2gtk-4.1`` (a small package)
    web-cef      — self-contained; bundles the Chromium Embedded Framework (a much bigger download)

If webkit2gtk-4.1 is present we grab web-webview; otherwise the user is asked to either install
webkit (then web-webview) or download the self-contained CEF build. Scene/video/image wallpapers
render regardless of the choice.

Environment overrides for non-interactive / scripted installs:

    KIRIE_WEB=webview|cef|none   pick the web backend without prompting
    KIRIE_FORCE=1               replace an existing ~/kirie-bin without asking
    KIRIE_SKIP=1                skip this step entirely

A failure is reported as a warning and does NOT abort the rest of the installation.
"""

from __future__ import annotations

import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Optional

if __package__ in (None, ""):
    sys.path.append(str(Path(__file__).resolve().parent.parent))
    from components.utils import run_cmd
    from components.presentation import print_step, print_success, print_warning
else:
    from .utils import run_cmd
    from .presentation import print_step, print_success, print_warning

REPO = "beingsuz/kirie"
DEST = Path.home() / "kirie-bin"
BIN_SYMLINK = Path.home() / ".local" / "bin" / "kirie"

# release asset -> the artifact (dir + binary) name inside the tarball
ASSETS = {
    "webview": "kirie-web-webview-linux-x86_64.tar.gz",
    "cef": "kirie-web-cef-linux-x86_64.tar.gz",
    "none": "kirie-linux-x86_64.tar.gz",
}
# webkit runtime the web-webview build links against
WEBKIT_PKG = "webkit2gtk-4.1"


# --------------------------------------------------------------------------- helpers

def _env(name: str) -> Optional[str]:
    value = (os.environ.get(name) or "").strip()
    return value or None


def _truthy(name: str) -> bool:
    return (os.environ.get(name) or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def _webkit_present() -> bool:
    """True if the system webkit2gtk-4.1 runtime the web-webview build needs is installed."""
    if run_cmd(["pkg-config", "--exists", WEBKIT_PKG], check=False).returncode == 0:
        return True
    # pkg-config may be absent even when the runtime lib is; check the shared object too.
    probe = run_cmd(
        ["sh", "-c", "ldconfig -p 2>/dev/null | grep -q 'libwebkit2gtk-4.1'"], check=False
    )
    return probe.returncode == 0


# --------------------------------------------------------------------------- variant selection

def _choose_variant(aur_helper: str) -> Optional[str]:
    """Return the web backend key ('webview' | 'cef' | 'none'), or None to skip."""
    if _truthy("KIRIE_SKIP"):
        print_warning("KIRIE_SKIP set — skipping the wallpaper renderer.")
        return None

    forced = (_env("KIRIE_WEB") or "").lower()
    if forced in ASSETS:
        return forced

    if _webkit_present():
        print_success(f"{WEBKIT_PKG} found — using the light web-webview build.")
        return "webview"

    # webkit missing: install it (light) or fall back to the self-contained CEF build.
    if not sys.stdin.isatty():
        print_warning(
            f"{WEBKIT_PKG} not found and no TTY — downloading the self-contained CEF build. "
            "Set KIRIE_WEB=webview and install webkit2gtk-4.1 for the lighter one."
        )
        return "cef"

    print(f"Web wallpapers need a browser backend, and {WEBKIT_PKG} is not installed.")
    print(f"  1) Install {WEBKIT_PKG} (small) and use the light web-webview build  [recommended]")
    print("  2) Download the self-contained CEF build (much bigger, no extra packages)")
    print("  3) No web backend (scene / video / image wallpapers only)")
    choice = input("  Choose [1/2/3, default 1]: ").strip() or "1"

    if choice == "2":
        return "cef"
    if choice == "3":
        return "none"

    print_step("*", f"Installing {WEBKIT_PKG}")
    result = run_cmd([aur_helper, "-S", "--needed", WEBKIT_PKG], check=False)
    if result.returncode != 0 or not _webkit_present():
        print_warning(f"Could not install {WEBKIT_PKG} — falling back to the CEF build.")
        return "cef"
    return "webview"


# --------------------------------------------------------------------------- download + unpack

def _confirm_overwrite() -> bool:
    if _truthy("KIRIE_FORCE"):
        return True
    if not sys.stdin.isatty():
        return True  # non-interactive: a re-run should refresh the binary
    answer = input(f"  {DEST} already exists. Replace it? [Y/n]: ").strip().lower()
    return answer in ("", "y", "yes")


def _download(asset: str) -> Path:
    url = f"https://github.com/{REPO}/releases/latest/download/{asset}"
    print_step("*", f"Downloading {asset}")
    tmp = Path(tempfile.mkdtemp()) / asset
    # prefer curl (progress + redirects) if present, else urllib
    if shutil.which("curl"):
        run_cmd(["curl", "-fL", "--progress-bar", "-o", str(tmp), url])
    else:
        urllib.request.urlretrieve(url, tmp)  # noqa: S310 — trusted github release URL
    if not tmp.is_file() or tmp.stat().st_size == 0:
        raise RuntimeError(f"download produced no file: {url}")
    return tmp


def _install_tarball(tarball: Path, asset: str) -> None:
    """Unpack the release tarball into DEST, renaming the variant binary to `kirie`."""
    artifact = asset[: -len("-linux-x86_64.tar.gz")]  # e.g. kirie-web-webview

    if DEST.exists():
        if not _confirm_overwrite():
            print_warning(f"Keeping existing {DEST}.")
            return
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True, exist_ok=True)

    extract_dir = Path(tempfile.mkdtemp())
    with tarfile.open(tarball, "r:gz") as tar:
        tar.extractall(extract_dir)  # noqa: S202 — trusted release artifact

    inner = extract_dir / artifact
    src_dir = inner if inner.is_dir() else extract_dir
    for item in src_dir.iterdir():
        # the main binary is named after the artifact; everything else (CEF helper, *.pak,
        # *.bin, locales/) sits beside it and must land next to the binary.
        target = DEST / ("kirie" if item.name == artifact else item.name)
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)
    shutil.rmtree(extract_dir, ignore_errors=True)

    binary = DEST / "kirie"
    if not binary.is_file():
        raise RuntimeError(f"unpacked {asset} but {binary} is missing")
    binary.chmod(0o755)

    # PATH symlink so `command -v kirie` works (the daemon also looks at ~/kirie-bin/kirie directly)
    BIN_SYMLINK.parent.mkdir(parents=True, exist_ok=True)
    if BIN_SYMLINK.is_symlink() or BIN_SYMLINK.exists():
        BIN_SYMLINK.unlink()
    BIN_SYMLINK.symlink_to(binary)

    print_success(f"Installed kirie -> {binary}")


def _print_steam_notice() -> None:
    print("")
    print_warning(
        "Wallpaper Engine assets come from Steam: you must OWN and install Wallpaper Engine "
        "(via Steam, Proton/Windows build) so its Workshop items appear under "
        "~/.local/share/Steam/steamapps/workshop/content/431960. Subscribe to wallpapers in Steam, "
        "then pick them with Super+W."
    )


# --------------------------------------------------------------------------- entrypoint

def install_wallpaper_engine(aur_helper: str = "yay") -> None:
    run_cmd(["sh", "-c", "figlet 'KIRIE' -f slant | lolcat"], check=False)

    try:
        variant = _choose_variant(aur_helper)
        if variant is None:
            return
        tarball = _download(ASSETS[variant])
        _install_tarball(tarball, ASSETS[variant])
        shutil.rmtree(tarball.parent, ignore_errors=True)
        _print_steam_notice()
    except Exception as exc:  # noqa: BLE001 — never abort the whole install for this optional step
        print_warning(f"kirie setup failed: {exc}")
        print_warning(
            "You can finish it later: download a release from "
            "https://github.com/beingsuz/kirie/releases and unpack the binary to ~/kirie-bin/kirie."
        )


def main() -> None:
    aur_helper = sys.argv[1] if len(sys.argv) > 1 else "yay"
    install_wallpaper_engine(aur_helper)


if __name__ == "__main__":
    main()
