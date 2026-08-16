#!/bin/bash

AGS_TMP="/tmp/ags-${USER}"
mkdir -p "$AGS_TMP"

# Bundle before stopping the running shell: a bundle that fails (syntax error,
# missing import) used to leave the desktop with no bar at all, because the old
# instance had already been killed.
if ! ags bundle "$HOME/.config/ags/app.tsx" "$AGS_TMP/ags-bin.new"; then
    echo "bar.sh: bundle failed, keeping the running shell" >&2
    exit 1
fi
mv "$AGS_TMP/ags-bin.new" "$AGS_TMP/ags-bin"

ags quit

killall gjs >/dev/null 2>&1

# output log to $AGS_TMP/ags-bin.log
nohup "$AGS_TMP/ags-bin" > "$AGS_TMP/ags-bin.log" 2>&1 &

exit 0
