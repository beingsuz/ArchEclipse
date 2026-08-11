import GLib from "gi://GLib";

/**
 * Trailing-edge debounce on the GLib main loop. The returned function delays
 * `fn` until `ms` of quiet; each call resets the timer and remembers the
 * latest arguments. `.cancel()` drops a pending call, `.flush()` runs it now.
 */
export function debounce<A extends any[]>(
  ms: number,
  fn: (...args: A) => void,
) {
  let source: number | null = null;
  let pending: A | null = null;

  const clear = () => {
    if (source !== null) {
      GLib.source_remove(source);
      source = null;
    }
  };

  const wrapped = (...args: A) => {
    pending = args;
    clear();
    source = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
      source = null;
      const a = pending as A;
      pending = null;
      fn(...a);
      return GLib.SOURCE_REMOVE;
    });
  };

  wrapped.cancel = () => {
    clear();
    pending = null;
  };
  wrapped.flush = () => {
    if (pending !== null) {
      const a = pending;
      wrapped.cancel();
      fn(...a);
    }
  };

  return wrapped;
}
