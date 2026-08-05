import { createState, For, With } from "ags";
import { execAsync } from "ags/process";
import { Gtk } from "ags/gtk4";
import { timeout } from "ags/time";
import Hyprland from "gi://AstalHyprland";
import GLib from "gi://GLib";
import { readJson } from "../utils/json";
import { notify } from "../utils/notification";

const engine = `${GLib.get_home_dir()}/.config/hypr/wallpaper-daemon/wallpaperengine.sh`;

interface WeProp {
  key: string;
  type: string;
  text: string;
  value: any;
  options?: any[] | null;
  min?: number | null;
  max?: number | null;
  step?: number | null;
}

type RGB = [number, number, number];

const clamp255 = (n: number) => Math.max(0, Math.min(255, Math.round(n * 255)));

// A Wallpaper Engine colour is "r g b" with components in 0..1.
const parseColor = (value: any): RGB => {
  const p = String(value).trim().split(/\s+/).map(Number);
  return [p[0] || 0, p[1] || 0, p[2] || 0];
};
const rgbCss = ([r, g, b]: RGB) =>
  `rgb(${clamp255(r)},${clamp255(g)},${clamp255(b)})`;
const rgbToHex = ([r, g, b]: RGB) =>
  `#${[r, g, b].map((n) => clamp255(n).toString(16).padStart(2, "0")).join("")}`;
const hexToRgb = (hex: string): RGB | null => {
  const m = /^#?([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
};
// The engine reads a colour without a decimal point as 0..255 and with one as
// 0..1, so always emit floats with a forced decimal point.
const rgbToWe = ([r, g, b]: RGB) =>
  `${r.toFixed(5)} ${g.toFixed(5)} ${b.toFixed(5)}`;

const isTruthy = (v: any) => v === true || v === 1 || v === "1" || v === "true";

const fmtNumber = (n: number) =>
  Number.isInteger(n) ? String(n) : n.toFixed(Math.abs(n) < 1 ? 3 : 2);

/**
 * Inline RGB picker. Not Gtk.ColorButton: its chooser opens as a separate
 * top-level window, which Hyprland shows as a stray floating app window. A
 * nested popover renders inside the layer-shell surface instead.
 */
function ColorControl({
  value,
  onChange,
}: {
  value: any;
  onChange: (we: string, debounce: boolean) => void;
}) {
  const init = parseColor(value);
  const [color, setColor] = createState<RGB>(init);

  const Channel = ({ label, index }: { label: string; index: number }) => (
    <box class="we-color-channel" spacing={6} valign={Gtk.Align.CENTER}>
      <label label={label} />
      <slider
        class="we-color-slider"
        widthRequest={150}
        hexpand
        min={0}
        max={1}
        step={1 / 255}
        value={init[index]}
        onValueChanged={(self) => {
          const next = [...color.peek()] as RGB;
          next[index] = self.get_value();
          setColor(next);
          onChange(rgbToWe(next), true);
        }}
      />
      <label label={color((c) => String(clamp255(c[index])))} />
    </box>
  );

  return (
    <menubutton class="we-color-button" halign={Gtk.Align.START}>
      <box
        class="we-color-swatch"
        widthRequest={40}
        heightRequest={20}
        css={color((c) => `background-color: ${rgbCss(c)};`)}
      />
      <popover>
        <box
          class="we-color-popover"
          orientation={Gtk.Orientation.VERTICAL}
          spacing={8}
        >
          <box
            heightRequest={24}
            css={color((c) => `background-color: ${rgbCss(c)};`)}
          />
          <Channel label="R" index={0} />
          <Channel label="G" index={1} />
          <Channel label="B" index={2} />
          <box spacing={6} valign={Gtk.Align.CENTER}>
            <label label="Hex" />
            <entry
              hexpand
              text={color((c) => rgbToHex(c))}
              onActivate={(self) => {
                const rgb = hexToRgb(self.text);
                if (rgb) {
                  setColor(rgb);
                  onChange(rgbToWe(rgb), false);
                }
              }}
            />
          </box>
        </box>
      </popover>
    </menubutton>
  );
}

/** Slider with a live numeric readout. */
function SliderControl({
  prop,
  onChange,
}: {
  prop: WeProp;
  onChange: (value: string, debounce: boolean) => void;
}) {
  const [val, setVal] = createState<number>(Number(prop.value) || 0);
  return (
    <box spacing={8} valign={Gtk.Align.CENTER} halign={Gtk.Align.START}>
      <slider
        widthRequest={180}
        min={prop.min ?? 0}
        max={prop.max ?? 1}
        step={prop.step ?? 0.01}
        value={Number(prop.value) || 0}
        onValueChanged={(self) => {
          setVal(self.get_value());
          onChange(String(self.get_value()), true);
        }}
      />
      <label label={val((v) => fmtNumber(v))} />
    </box>
  );
}

/**
 * Editor for the customizable properties a Wallpaper Engine wallpaper declares
 * (bool / slider / color / combo / textinput). Everything is addressed by
 * monitor: the daemon script knows which item is applied there, so this widget
 * never needs the Steam workshop path.
 */
export function WallpaperEngineProperties({
  monitorName,
}: {
  monitorName?: string;
}) {
  const [weId, setWeId] = createState<string>("");
  const [props, setProps] = createState<WeProp[]>([]);

  const monitor = () =>
    monitorName ?? Hyprland.get_default().get_focused_monitor()?.name ?? "";

  // One timer per property, so dragging a slider does not push a value on every
  // tick (each push can cost the engine a rebuild).
  const timers = new Map<string, ReturnType<typeof timeout>>();

  const setProp = (key: string, value: string, debounce = false) => {
    const m = monitor();
    const apply = () =>
      // Persist the override, then push it live. The engine applies plain values
      // in place and rebuilds in-process for visibility-gating ones; only an
      // unreachable engine needs the wallpaper reloaded.
      execAsync(["bash", engine, "properties", "set", m, key, value])
        .then(() =>
          execAsync(["bash", engine, "ctl", "property", key, value]).catch(() =>
            execAsync(["bash", engine, "restart", m]),
          ),
        )
        .catch((err) => notify({ summary: "Error", body: String(err) }));

    if (!debounce) return void apply();
    timers.get(key)?.cancel?.();
    timers.set(key, timeout(450, apply));
  };

  const load = async () => {
    const m = monitor();
    try {
      setWeId((await execAsync(["bash", engine, "properties", "current", m])).trim());
      const out = await execAsync(["bash", engine, "properties", "list", m]);
      setProps((readJson(out) as WeProp[]) || []);
    } catch {
      setWeId("");
      setProps([]);
    }
  };

  const resetAll = () =>
    execAsync(["bash", engine, "properties", "reset", monitor()])
      .then(load)
      .catch((err) => notify({ summary: "Error", body: String(err) }));

  const Control = (p: WeProp) => {
    switch (p.type) {
      case "bool":
        return (
          <switch
            valign={Gtk.Align.CENTER}
            halign={Gtk.Align.START}
            active={isTruthy(p.value)}
            onNotifyActive={(self) =>
              setProp(p.key, self.active ? "true" : "false")
            }
          />
        );
      case "slider":
        return (
          <SliderControl
            prop={p}
            onChange={(value, debounce) => setProp(p.key, value, debounce)}
          />
        );
      case "combo": {
        const opts = p.options || [];
        // A combo without a stored value reports null; Wallpaper Engine treats
        // that as the first option, so show it selected rather than nothing.
        const current =
          p.value === null || p.value === undefined || p.value === ""
            ? String(opts.length ? (opts[0]?.value ?? opts[0]) : "")
            : String(p.value);
        return (
          <box
            spacing={4}
            halign={Gtk.Align.START}
            $={(self: any) => {
              // A combo is single-choice: link the toggles into one radio group
              // so selecting one releases the others.
              let leader: any = null;
              for (let c = self.get_first_child(); c; c = c.get_next_sibling()) {
                if (leader === null) leader = c;
                else c.set_group?.(leader);
              }
            }}
          >
            {opts.map((o: any) => {
              const value = String(o?.value ?? o);
              return (
                <togglebutton
                  label={String(o?.label ?? o?.text ?? value)}
                  active={current === value}
                  onToggled={({ active }) => active && setProp(p.key, value)}
                />
              );
            })}
          </box>
        );
      }
      case "color":
        return (
          <ColorControl
            value={p.value}
            onChange={(we, debounce) => setProp(p.key, we, debounce)}
          />
        );
      default:
        // textinput and anything unknown
        return (
          <entry
            widthRequest={160}
            halign={Gtk.Align.START}
            text={String(p.value ?? "")}
            onActivate={(self) => setProp(p.key, self.text)}
          />
        );
    }
  };

  return (
    <menubutton class="we-properties" halign={Gtk.Align.START}>
      <label label="Wallpaper Properties" />
      <popover $={(self) => self.connect("show", load)}>
        <box
          class="popover we-properties-popover"
          orientation={Gtk.Orientation.VERTICAL}
          spacing={8}
          widthRequest={340}
        >
          <With value={weId}>
            {(id) =>
              !id ? (
                <label
                  label="Apply a Wallpaper Engine wallpaper to customize it."
                  wrap
                />
              ) : (
                <box orientation={Gtk.Orientation.VERTICAL} spacing={8}>
                  <Gtk.ScrolledWindow
                    hscrollbarPolicy={Gtk.PolicyType.NEVER}
                    heightRequest={360}
                    propagateNaturalHeight
                  >
                    <box orientation={Gtk.Orientation.VERTICAL} spacing={10}>
                      <For each={props}>
                        {(p) => (
                          <box
                            class="we-property"
                            orientation={Gtk.Orientation.VERTICAL}
                            spacing={3}
                          >
                            <label label={p.text || p.key} xalign={0} wrap />
                            {Control(p)}
                          </box>
                        )}
                      </For>
                    </box>
                  </Gtk.ScrolledWindow>
                  <button label="Reset to defaults" onClicked={resetAll} />
                </box>
              )
            }
          </With>
        </box>
      </popover>
    </menubutton>
  );
}
