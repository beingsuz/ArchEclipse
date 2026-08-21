#!/usr/bin/env python3
"""Apply default configurations.

Copy default hyprland configuration files from .config/hypr/config/defaults
to .config/hypr/config/custom and register the configured file manager as the
default directory handler.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
import shutil

if __package__ in (None, ""):
    sys.path.append(str(Path(__file__).resolve().parent.parent))
    from components.utils import run_cmd, run_shell
else:
    from .utils import run_cmd, run_shell

AGS_SETTINGS_FILE = Path.home() / ".config/ags/cache/settings/settings.json"
DEFAULT_FILE_MANAGER = "nautilus"
TERMINAL = "kitty"
OPEN_ANY_TERMINAL_SCHEMA = "com.github.stunkymonkey.nautilus-open-any-terminal"

# AGS `fileManager` setting -> desktop entry registered for inode/directory
FILE_MANAGER_DESKTOP_ENTRIES: dict[str, str] = {
    "nautilus": "org.gnome.Nautilus.desktop",
    "thunar": "thunar.desktop",
    "dolphin": "org.kde.dolphin.desktop",
    "nemo": "nemo.desktop",
    "pcmanfm": "pcmanfm.desktop",
    "ranger": "ranger.desktop",
}


def _copy_children(src_dir: Path, dst_dir: Path) -> None:
    dst_dir.mkdir(parents=True, exist_ok=True)
    for child in src_dir.iterdir():
        dst = dst_dir / child.name
        if child.is_dir():
            shutil.copytree(child, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(child, dst)


def apply_defaults() -> None:
    run_shell("figlet 'DEFAULTS' -f slant | lolcat", check=False)

    src_dir = Path.home() / ".config/hypr/config/defaults"
    dst_dir = Path.home() / ".config/hypr/config/custom"

    print(
        "Copying default hyprland configuration files from "
        f"{src_dir} to {dst_dir}..."
    )
    _copy_children(src_dir, dst_dir)
    print("Done.")

    print("Default hyprland configuration files copied successfully.")

    apply_file_manager_defaults()


def configured_file_manager() -> str:
    """File manager picked in the AGS settings, falling back to the default."""
    try:
        settings = json.loads(AGS_SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        return DEFAULT_FILE_MANAGER
    file_manager = settings.get("fileManager") if isinstance(settings, dict) else None
    if isinstance(file_manager, str) and file_manager:
        return file_manager
    return DEFAULT_FILE_MANAGER


def _desktop_entry_installed(entry: str) -> bool:
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    search_dirs = [Path(data_home), *(Path(d) for d in data_dirs.split(":") if d)]
    return any((d / "applications" / entry).is_file() for d in search_dirs)


def _gsettings_schema_exists(schema: str) -> bool:
    result = run_cmd(["gsettings", "list-schemas"], check=False, capture_output=True)
    return schema in (result.stdout or "").split()


def apply_file_manager_defaults() -> None:
    """Register the configured file manager as default directory handler."""
    file_manager = configured_file_manager()
    desktop_entry = FILE_MANAGER_DESKTOP_ENTRIES.get(file_manager)

    if desktop_entry is None:
        print(f"Unknown file manager '{file_manager}', skipping default handler.")
    elif not shutil.which("xdg-mime"):
        print("xdg-mime not found, skipping default handler.")
    elif not _desktop_entry_installed(desktop_entry):
        print(f"{desktop_entry} not installed, skipping default handler.")
    else:
        print(f"Setting {desktop_entry} as default handler for directories...")
        run_cmd(["xdg-mime", "default", desktop_entry, "inode/directory"], check=False)

    if shutil.which("gsettings") and _gsettings_schema_exists(OPEN_ANY_TERMINAL_SCHEMA):
        print(f"Setting Nautilus 'Open in Terminal' to {TERMINAL}...")
        run_cmd(
            ["gsettings", "set", OPEN_ANY_TERMINAL_SCHEMA, "terminal", TERMINAL],
            check=False,
        )


def main() -> None:
    apply_defaults()

if __name__ == "__main__":
    main()