#!/bin/bash
set -uo pipefail

AGS_TMP="/tmp/ags-${USER}"
mkdir -p "$AGS_TMP"

BIN="$AGS_TMP/ags-bin"
LOG="$AGS_TMP/ags-bin.log"
LOCK_FILE="$AGS_TMP/bar.lock"
PID_FILE="$AGS_TMP/ags.pid"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SHELL_PATTERN="gjs -m ${RUNTIME_DIR}/.*ags\.js"
SUPERVISOR="$HOME/.config/hypr/scripts/ags-supervise.sh"

# Only one restart at a time. A screen turning off and back on used to queue
# several of these seconds apart, and two overlapping runs could leave two
# shells alive: the second run tore down the old gjs before the first run's
# replacement had spawned its own, so that replacement survived alongside it.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "bar.sh: a restart is already in flight, skipping" >&2
    exit 0
fi

# Bundle before stopping the running shell: a bundle that fails (syntax error,
# missing import) used to leave the desktop with no bar at all, because the old
# instance had already been killed.
if ! ags bundle "$HOME/.config/ags/app.tsx" "$BIN.new"; then
    echo "bar.sh: bundle failed, keeping the running shell" >&2
    exit 1
fi
mv "$BIN.new" "$BIN"

# Stop the previous shell and *wait* for it to be gone. The old `killall gjs`
# both raced the replacement and took down unrelated gjs applications, so kill
# only this shell: the recorded process group first, then anything still
# running our bundle.
stop_previous() {
    ags quit >/dev/null 2>&1

    local pid=""
    [ -r "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] &&
        tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q "ags-bin"; then
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    fi
    # The recorded pid is the supervisor's process group (it is a session
    # leader via setsid), so this reaches the shell it is running too. Matching
    # on the script name instead would risk killing whatever editing session
    # happens to have that name in its own command line.
    pkill -TERM -f "$SHELL_PATTERN" 2>/dev/null

    for _ in $(seq 1 40); do
        pgrep -f "$SHELL_PATTERN" >/dev/null 2>&1 || return 0
        sleep 0.25
    done

    echo "bar.sh: previous shell ignored SIGTERM, killing" >&2
    pkill -KILL -f "$SHELL_PATTERN" 2>/dev/null
    sleep 0.5
}
stop_previous

# Run under a supervisor: a shell that dies on its own (GTK crash, or a start
# that throws while the only monitor is off) otherwise leaves the desktop with
# no bar until it is restarted by hand.
#
# 9>&- matters: without it the new process inherits the locked descriptor and
# keeps the flock alive for its whole lifetime, so every later restart would
# decide one was already in flight and skip.
if [ -x "$SUPERVISOR" ]; then
    setsid nohup "$SUPERVISOR" "$BIN" "$LOG" "$PID_FILE" >/dev/null 2>&1 9>&- &
else
    setsid nohup "$BIN" >"$LOG" 2>&1 9>&- &
fi
echo $! >"$PID_FILE"

exit 0
