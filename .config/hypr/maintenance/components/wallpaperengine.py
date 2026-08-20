#!/usr/bin/env python3
"""Wallpaper Engine support: installs the kirie engine."""

from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.append(str(Path(__file__).resolve().parent.parent))
    from components.utils import run_cmd
else:
    from .utils import run_cmd

INSTALLER = ".config/hypr/wallpaper-daemon/kirie-install.sh"


def install_engine(conf_dir: Path | None = None) -> None:
    """Install the kirie wallpaper engine.

    Downloads a release binary into ~/.local/bin so Steam Workshop wallpapers
    work out of the box. Runs the script from the freshly cloned repository
    when one is given, so the installer does not depend on the configuration
    files having been synced already.
    """
    script = (conf_dir / INSTALLER) if conf_dir else (Path.home() / INSTALLER)

    if not script.exists():
        print(f"Wallpaper Engine installer not found: {script}")
        return

    # A failed download must not take the whole ArchEclipse install with it:
    # everything else still works, wallpapers just stay static until the engine
    # is installed (the wallpaper daemon retries on first use).
    run_cmd(["bash", str(script)], check=False)


def update_engine() -> None:
    """Refresh an installed engine to the current release.

    `--force` because the installed binary is exactly what install_engine()
    skips over; on update we do want the newer release.
    """
    script = Path.home() / INSTALLER

    if not script.exists():
        print(f"Wallpaper Engine installer not found: {script}")
        return

    run_cmd(["bash", str(script), "--force"], check=False)


def main() -> None:
    install_engine()


if __name__ == "__main__":
    main()
