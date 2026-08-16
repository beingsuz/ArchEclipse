import { Gdk } from "ags/gtk4";

import Gio from "gi://Gio";

const hyprlandMonitors = (): any[] => {
  try {
    const proc = Gio.Subprocess.new(
      ["hyprctl", "monitors", "-j"],
      Gio.SubprocessFlags.STDOUT_PIPE,
    );

    const [, stdout] = proc.communicate_utf8(null, null);
    return JSON.parse(stdout);
  } catch {
    return [];
  }
};

export function getConnectorFromHyprland(model: string) {
  for (const m of hyprlandMonitors()) {
    const desc = `${m.make ?? ""} ${m.model ?? ""} ${m.description ?? ""}`;
    if (desc.includes(model)) return m.name;
  }
}

export function getMonitorName(monitor: Gdk.Monitor) {
  // GTK4 provides get_connector() which returns Wayland connector name directly
  // This is more reliable than matching model strings against hyprctl output
  const connector = monitor.get_connector();
  if (connector) return connector;

  // Gdk hands out a monitor before it has resolved the connector on every
  // hotplug (turning a screen back on). Its position is already correct then,
  // and Hyprland reports one for every output, so match on that before
  // falling back to the description — otherwise every window built for the
  // returning monitor is named "<widget>-undefined" and `ags toggle` (i.e.
  // every panel keybind) stops resolving until the shell is restarted.
  const geometry = monitor.get_geometry();
  const byPosition = hyprlandMonitors().find(
    (m) => m.x === geometry.x && m.y === geometry.y,
  );
  if (byPosition) return byPosition.name as string;

  const model = monitor.get_model() || monitor.get_description();
  return model ? getConnectorFromHyprland(model as any) : undefined;
}
