#!/usr/bin/env python3
"""Mirror the current GTK theme into the user gtk-4.0 config for libadwaita apps.

libadwaita apps (Nautilus, Loupe, Calculator, ...) ignore the theme selected
via gsettings and ship their own stylesheet. GTK still loads
``$XDG_CONFIG_HOME/gtk-4.0/gtk.css`` for every GTK4 app, so the theme's
gtk-4.0 stylesheet and assets are mirrored there. This is the same approach
as WhiteSur's ``tweaks.sh -l`` libadwaita tweak, but works with the packaged
(gresource based) theme and re-runs on every theme switch.

Usage:
    libadwaita-theme.py <theme-name>   mirror /usr/share/themes/<theme-name>/gtk-4.0
    libadwaita-theme.py --clear        remove the mirrored theme
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import Iterator

RESOURCE_ROOT = "/org/gnome/theme/"
MARKER = ".archeclipse-theme"
MANAGED = ("gtk.css", "gtk-dark.css", "assets", "windows-assets")


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "gtk-4.0"


def theme_search_dirs() -> Iterator[Path]:
    yield Path.home() / ".themes"
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    yield Path(data_home) / "themes"
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    for data_dir in data_dirs.split(":"):
        if data_dir:
            yield Path(data_dir) / "themes"


def find_theme(name: str) -> Path | None:
    for base in theme_search_dirs():
        candidate = base / name / "gtk-4.0"
        if (candidate / "gtk.css").is_file():
            return candidate
    return None


def is_managed(dst: Path) -> bool:
    """True when gtk-4.0 is empty or was written by this script."""
    return (dst / MARKER).exists() or not (dst / "gtk.css").exists()


def clear(dst: Path) -> None:
    for name in (*MANAGED, MARKER):
        path = dst / name
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()


def extract_gresource(gresource: Path, dst: Path) -> None:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio

    resource = Gio.Resource.load(str(gresource))
    flags = Gio.ResourceLookupFlags.NONE

    def walk(path: str) -> None:
        for child in resource.enumerate_children(path, flags):
            full = path + child
            if child.endswith("/"):
                walk(full)
                continue
            target = dst / full[len(RESOURCE_ROOT):]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(resource.lookup_data(full, flags).get_data())

    walk(RESOURCE_ROOT)


def copy_plain(src: Path, dst: Path) -> None:
    for name in MANAGED:
        path = src / name
        if path.is_dir():
            shutil.copytree(path, dst / name, dirs_exist_ok=True)
        elif path.is_file():
            shutil.copy2(path, dst / name)


def apply(theme: str) -> int:
    dst = config_dir()
    src = find_theme(theme)
    if src is None:
        print(f"Error: no gtk-4.0 stylesheet found for theme '{theme}'", file=sys.stderr)
        return 1

    if not is_managed(dst):
        print(f"{dst / 'gtk.css'} is not managed by ArchEclipse, leaving it alone")
        return 0

    marker = dst / MARKER
    gresource = src / "gtk.gresource"
    sources = [p for p in (src / "gtk.css", gresource) if p.exists()]
    source_mtime = max(p.stat().st_mtime for p in sources)
    if (
        marker.exists()
        and marker.read_text().strip() == theme
        and marker.stat().st_mtime >= source_mtime
    ):
        print(f"libadwaita theme already up to date ({theme})")
        return 0

    dst.mkdir(parents=True, exist_ok=True)
    clear(dst)
    try:
        if gresource.is_file():
            extract_gresource(gresource, dst)
        else:
            copy_plain(src, dst)
    except Exception as exc:  # noqa: BLE001
        clear(dst)
        print(f"Error: failed to mirror theme '{theme}': {exc}", file=sys.stderr)
        return 1

    marker.write_text(f"{theme}\n")
    print(f"libadwaita theme set to {theme}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    if argv[1] == "--clear":
        dst = config_dir()
        if is_managed(dst):
            clear(dst)
            print("libadwaita theme removed")
        else:
            print(f"{dst / 'gtk.css'} is not managed by ArchEclipse, leaving it alone")
        return 0

    return apply(argv[1])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
