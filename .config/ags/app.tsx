import app from "ags/gtk4/app";
import Bar, {
  activateState,
  barState,
  deactivateState,
  setBarState,
  toggleBarShown,
} from "./widgets/bar/Bar";
import BarHover from "./widgets/bar/BarHover";
import { getCssPath } from "./utils/scss";
import { logTime, logTimeWidget } from "./utils/time";
import { compileBinaries } from "./utils/gcc";
import RightPanelHover from "./widgets/rightPanel/RightPanelHover";
import RightPanel from "./widgets/rightPanel/RightPanel";
import LeftPanel from "./widgets/leftPanel/LeftPanel";
import LeftPanelHover from "./widgets/leftPanel/LeftPanelHover";
import WallpaperSwitcher from "./widgets/WallpaperSwitcher";
import AppLauncher from "./widgets/applauncher/AppLauncher";
import UserPanel from "./widgets/UserPanel";
import NotificationPopups from "./widgets/NotificationPopups";
import { createState, For, onCleanup, This } from "ags";
import { timeout } from "ags/time";
import { execAsync } from "ags/process";
import Gdk from "gi://Gdk";
import { getMonitorName } from "./utils/monitor";
import Notifd from "gi://AstalNotifd";
import KeyStrokeVisualizer from "./widgets/KeyStrokeVisualizer";
import { leftPanelWidgetSelectors } from "./constants/widget.constants";
import { setGlobalSetting } from "./variables";
import { Gtk } from "ags/gtk4";
import AlwaysOnWidget from "./widgets/AlwaysOnWidget";
import { ensureAuthServerRunning } from "./utils/auth-session";
import { startFastfetchPinsSync } from "./services/fastfetch";
import { isRecording, toggleRecording } from "./services/record.service";
import { setSearchQuery } from "./widgets/bar/barStates/SearchBar";
const Notification = Notifd.get_default();

const perMonitorDisplay = () => {
  // Monitors are only rendered once they can be named. Gdk announces a
  // monitor before resolving its connector when a screen is turned back on,
  // and widgets bake that name in at construction, so building too early
  // leaves every window called "<widget>-undefined" — the panel keybinds
  // then resolve nothing until the shell restarts. Re-check when the
  // connector arrives, and give up waiting after a moment so an output we
  // cannot name still gets its bar.
  const [monitors, setMonitors] = createState<Gdk.Monitor[]>([]);
  const watched = new Set<Gdk.Monitor>();
  const unnamed = new Set<Gdk.Monitor>();

  const refreshMonitors = () => {
    const present = app.get_monitors();

    for (const monitor of present) {
      if (watched.has(monitor)) continue;
      watched.add(monitor);
      monitor.connect("notify::connector", refreshMonitors);
      timeout(2000, () => {
        if (watched.has(monitor) && !getMonitorName(monitor)) {
          unnamed.add(monitor);
          refreshMonitors();
        }
      });
    }

    for (const monitor of [...watched]) {
      if (!present.includes(monitor)) {
        watched.delete(monitor);
        unnamed.delete(monitor);
      }
    }

    setMonitors(
      present.filter((m) => !!getMonitorName(m) || unnamed.has(m)),
    );
  };

  app.connect("notify::monitors", refreshMonitors);
  refreshMonitors();
  // Windows belonging to a monitor that just went away. They are retired
  // rather than destroyed: destroying a layer-shell window whose output is
  // gone segfaults GTK 4.22 inside the application's window-removed handler
  // (deferring or detaching the window first does not help). Renaming frees
  // the name so the copy built when the monitor returns owns it, which is
  // what `ags toggle <window>-<monitor>` looks up.
  const retire = (win: any) => {
    win.hide();
    if (!win.name?.startsWith("zombie-")) {
      win.name = `zombie-${win.name}-${Date.now()}`;
    }
  };

  // Retired windows can never be released: GTK 4.22 segfaults on destroying a
  // layer-shell window whose output is gone (immediately, deferred, detached
  // or emptied first — all crash), and a per-monitor set holds ~200 MB. So
  // the shell recycles itself instead, which is both crash-free and leak-free.
  // Debounced, because a hotplug storm emits several removals.
  let restartQueued = false;
  const recycleShell = () => {
    if (restartQueued) return;
    restartQueued = true;
    timeout(3000, () => {
      execAsync([
        "bash",
        "-c",
        `setsid nohup "$HOME/.config/hypr/scripts/bar.sh" >/dev/null 2>&1 &`,
      ]).catch(() => (restartQueued = false));
    });
  };

  const retireWindows = (connector: string) => {
    for (const win of app.get_windows() as any[]) {
      const name: string | null = win.name;
      if (!name || name.startsWith("zombie-")) continue;
      if (name !== connector && !name.endsWith(`-${connector}`)) continue;
      retire(win);
    }
  };

  const createWidget = (Widget: any, monitor: any) => () => (
    <Widget
      monitor={monitor}
      setup={(self: any) => onCleanup(() => retire(self))}
    />
  );
  const widgets = [
    Bar,
    BarHover,
    RightPanel,
    RightPanelHover,
    LeftPanel,
    LeftPanelHover,
    NotificationPopups,
    UserPanel,
    WallpaperSwitcher,
    AlwaysOnWidget,
    KeyStrokeVisualizer,
  ];

  return (
    <For each={monitors}>
      {(monitor) => (
        <This this={app}>
          {(() => {
            const connector = getMonitorName(monitor) as string;
            // Widgets that register windows themselves (rather than through
            // the factory below) are retired by this sweep.
            onCleanup(() => {
              retireWindows(connector);
              recycleShell();
            });
            return widgets.map((Widget) =>
              logTimeWidget(connector, createWidget(Widget, monitor)),
            );
          })()}
        </This>
      )}
    </For>
  );
};

app.start({
  css: getCssPath(),
  main: () => {
    ensureAuthServerRunning();
    startFastfetchPinsSync();
    logTime("Compiling Binaries", () => compileBinaries());
    logTime("\tInitializing Per-Monitor Display", () => perMonitorDisplay());
  },
  async requestHandler(argv: string[], response: (response: string) => void) {
    const [cmd, arg, ...rest] = argv;
    const monitor = arg;

    const prefillLauncherInput = (window: any, value: string) => {
      const input = window?.entry as Gtk.TextView | Gtk.Entry | undefined;
      if (!input) return;

      if (
        "buffer" in input &&
        input.buffer &&
        "get_end_iter" in input.buffer &&
        "place_cursor" in input.buffer
      ) {
        const buffer = input.buffer as Gtk.TextBuffer;
        buffer.text = value;
        const iter = buffer.get_end_iter();
        buffer.place_cursor(iter);
        input.grab_focus();
        return;
      }

      if ("set_text" in input) {
        (input as Gtk.Entry).set_text(value);
        (input as Gtk.Entry).set_position(-1);
        (input as Gtk.Entry).grab_focus();
      }
    };

                if (cmd == "delete-notification") {
      const id = parseInt(arg);
      const notification = Notification.notifications.find((n) => n.id === id);
      if (notification) {
        notification.dismiss();
        response(`Notification ${id} dismissed.`);
      } else {
        response(`Notification ${id} not found.`);
      }
      return;
    } else if (cmd == "donations") {
      const leftPanel = app.get_window(`left-panel-${monitor}`);
      if (leftPanel) {
        leftPanel.show();
        setGlobalSetting(
          "leftPanel.widget",
          leftPanelWidgetSelectors.find((w) => w.name === "Donations"),
        );
      }
      response("Donations widget opened.");
      return;
    } else if (cmd == "clipboard") {
      activateState("search");
      setSearchQuery("cb ");
      response("Clipboard widget opened.");
      return;
    } else if (cmd == "emojis") {
      activateState("search");
      setSearchQuery("emoji ");
      response("Emoji picker opened.");
      return;
    } else if (cmd == "notes") {
      activateState("search");
      setSearchQuery("note ");
      response("Notes widget opened.");
      return;
    } else if (cmd == "apps") {
      activateState("search");
      setSearchQuery("apps ");
      response("Apps list opened.");
      return;
    }

    if (cmd == "screenrecord") {
      const state = await toggleRecording(arg as "now" | "area");
      response(`Recording ${state}.`);
      return;
    }

    if (cmd == "search") {
      if (barState.peek() === "search") {
        deactivateState("search");
      } else {
        activateState("search");
      }
      response("Search toggled.");
      return;
    }

    if (cmd == "bar") {
      toggleBarShown(monitor);
      response("Bar toggled.");
      return;
    }
    response("unknown command");
  },
});
