import Gio from "gi://Gio";
import GLib from "gi://GLib";
import Hyprland from "gi://AstalHyprland";

// Direct client for the kirie wallpaper engine's control socket.
//
// The engine owns $XDG_RUNTIME_DIR/lwe.sock and speaks a line protocol with a
// strict ONE COMMAND PER CONNECTION contract (kirie-ipc server): connect,
// write one line, read the single reply line, the engine closes. That shape
// maps 1:1 onto a short-lived Gio socket connection, so nothing here needs a
// daemon, a shell, or state — each call is self-contained and there is
// nothing to reconnect after an AGS restart.
//
// Replaces the `bash → hyprctl | jq → socat` chains of
// wallpaperengine-ctl.sh / wallpaperengine-properties.sh for AGS callers
// (the scripts remain for terminal use).

const SOCKET_PATH = `${GLib.getenv("XDG_RUNTIME_DIR") ?? "/tmp"}/lwe.sock`;

/** Parsed form of the engine's `status` reply (compat text format:
 * `speed=<f>` then one `screen=<name> bg=<path>` line per screen). */
export interface KirieStatus {
  speed: number;
  screens: { screen: string; bg: string }[];
}

/** One entry of the engine's `getproperties` reply (project.json property
 * schema with the live overrides folded into `value`). */
export interface KirieProp {
  key: string;
  type: string;
  text: string;
  value: any;
  options?: any[] | null;
  min?: number | null;
  max?: number | null;
  step?: number | null;
}

/**
 * Send one command line to the engine and resolve with its reply line
 * (`ok` / `error` / `pong` / one-line JSON). Rejects on a missing socket,
 * a timeout, or a closed-without-reply connection — the callers' existing
 * catch paths (notify / restart fallback) handle those.
 *
 * `bg` gets a long default timeout: the engine replies only after the
 * wallpaper is actually applied, and a heavy scene load takes seconds.
 */
export function kirieCmd(
  cmd: string,
  timeoutMs = cmd.startsWith("bg ") ? 10000 : 2000,
): Promise<string> {
  return kirieCmdLines(cmd, timeoutMs).then((lines) => lines[0] ?? "");
}

/**
 * Like [`kirieCmd`] but collects every reply line until the engine closes the
 * connection — `status` is the one multi-line reply in the protocol.
 */
export function kirieCmdLines(
  cmd: string,
  timeoutMs = 2000,
): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const cancellable = new Gio.Cancellable();
    let timer: GLib.Source | number | null = GLib.timeout_add(
      GLib.PRIORITY_DEFAULT,
      timeoutMs,
      () => {
        timer = null;
        cancellable.cancel();
        reject(new Error(`kirie: "${cmd}" timed out after ${timeoutMs}ms`));
        return GLib.SOURCE_REMOVE;
      },
    );
    const done = (fn: () => void) => {
      if (timer !== null) {
        GLib.source_remove(timer as number);
        timer = null;
      }
      fn();
    };

    const client = new Gio.SocketClient();
    client.connect_async(
      Gio.UnixSocketAddress.new(SOCKET_PATH),
      cancellable,
      (_c, res) => {
        let conn: Gio.SocketConnection;
        try {
          conn = client.connect_finish(res);
        } catch (e) {
          done(() => reject(new Error(`kirie: engine not reachable (${e})`)));
          return;
        }
        const closeConn = () => {
          try {
            conn.close(null);
          } catch {}
        };
        conn.get_output_stream().write_bytes_async(
          new GLib.Bytes(new TextEncoder().encode(cmd + "\n")),
          GLib.PRIORITY_DEFAULT,
          cancellable,
          (stream, wres) => {
            try {
              (stream as Gio.OutputStream).write_bytes_finish(wres);
            } catch (e) {
              closeConn();
              done(() => reject(new Error(`kirie: write failed (${e})`)));
              return;
            }
            const input = new Gio.DataInputStream({
              base_stream: conn.get_input_stream(),
              close_base_stream: false,
            });
            const lines: string[] = [];
            const readNext = () =>
              input.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, (_s, rres) => {
                let line: string | null = null;
                try {
                  const [raw] = input.read_line_finish_utf8(rres);
                  line = raw;
                } catch (e) {
                  closeConn();
                  done(() => reject(new Error(`kirie: read failed (${e})`)));
                  return;
                }
                if (line !== null) {
                  lines.push(line.trim());
                  readNext();
                  return;
                }
                // EOF — the engine closed after its reply (its contract).
                closeConn();
                done(() => {
                  if (lines.length === 0)
                    reject(new Error("kirie: connection closed without a reply"));
                  else resolve(lines);
                });
              });
            readNext();
          },
        );
      },
    );
  });
}

/** A reply the engine accepted (mirrors wallpaperengine-ctl.sh's test). */
const accepted = (reply: string) =>
  reply !== "" && !reply.startsWith("error") && !reply.startsWith("unknown command");

/** Screen-scoped verbs that take the monitor as their first argument. */
const SCREEN_SCOPED = new Set(["scaling", "clamp", "property"]);

/**
 * Send a live control command, inserting the monitor for screen-scoped verbs
 * and fanning those across every connected monitor (AstalHyprland — no
 * hyprctl|jq). Resolves `true` when at least one send was accepted, exactly
 * like wallpaperengine-ctl.sh's exit status.
 */
export async function kirieControl(args: string): Promise<boolean> {
  const verb = args.split(/\s+/, 1)[0];
  if (!SCREEN_SCOPED.has(verb)) return kirieCmd(args).then(accepted);

  const rest = args.slice(verb.length).trimStart();
  const monitors = Hyprland.get_default()
    .get_monitors()
    .map((m) => m.get_name());
  if (monitors.length === 0) return false;
  const results = await Promise.allSettled(
    monitors.map((mon) => kirieCmd(`${verb} ${mon} ${rest}`)),
  );
  return results.some((r) => r.status === "fulfilled" && accepted(r.value));
}

/** `status` → parsed snapshot (screens with their background paths). */
export const kirieStatus = (): Promise<KirieStatus> =>
  kirieCmdLines("status").then((lines) => {
    const out: KirieStatus = { speed: 1, screens: [] };
    for (const line of lines) {
      if (line.startsWith("speed=")) {
        out.speed = parseFloat(line.slice(6)) || 1;
      } else if (line.startsWith("screen=")) {
        // `screen=<name> bg=<path>` — the path may contain spaces.
        const bgAt = line.indexOf(" bg=");
        if (bgAt > 7)
          out.screens.push({
            screen: line.slice(7, bgAt),
            bg: line.slice(bgAt + 4),
          });
      }
    }
    return out;
  });

/** The workshop id rendered on `monitor` (last component of the screen's
 * background path), or `""` when the engine is down / not on that screen. */
export const kirieWorkshopId = (monitor: string): Promise<string> =>
  kirieStatus()
    .then((st) => {
      const bg = st.screens.find((s) => s.screen === monitor)?.bg ?? "";
      const id = bg.split("/").filter(Boolean).pop() ?? "";
      return /^\d+$/.test(id) ? id : "";
    })
    .catch(() => "");

/** `getproperties <screen>` → the wallpaper's property schema with live
 * override values folded in (kirie merges them engine-side), in the
 * project.json editor order. */
export const kirieProperties = (monitor: string): Promise<KirieProp[]> =>
  kirieCmd(`getproperties ${monitor}`).then((s) =>
    (JSON.parse(s) as (KirieProp & { order?: number })[]).sort(
      (a, b) => (a.order ?? 0) - (b.order ?? 0),
    ),
  );
