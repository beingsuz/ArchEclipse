#!/bin/bash
#
# wallpaperengine-properties.sh --list|--set|--reset <id> [key value]
#                               --current <monitor>
#
# Per-wallpaper property overrides, stored one key=value per line in
# config/properties/<id>.conf and passed to the engine as --set-property.

hyprDir="$HOME/.config/hypr"
WORKSHOP_DIR="${WE_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/431960}"
PROPS_DIR="$hyprDir/wallpaper-daemon/config/properties"

cmd="$1"

props_file() { echo "$PROPS_DIR/$1.conf"; }

case "$cmd" in
    --list)
        id="$2"
        proj="$WORKSHOP_DIR/$id/project.json"
        [ -f "$proj" ] || { echo "[]"; exit 0; }

        # base properties
        base="$(jq -c '
            (.general.properties // {})
            | to_entries
            | map({
                key: .key,
                type: (.value.type // "unknown"),
                text: (.value.text // .key),
                value: (.value.value // null),
                options: (.value.options // null),
                min: (.value.min // null),
                max: (.value.max // null),
                step: (.value.step // null),
                order: (.value.order // 0)
              })
            | sort_by(.order)
        ' "$proj" 2>/dev/null)"
        [ -z "$base" ] && base="[]"

        # saved overrides
        ov="{}"
        cfile="$(props_file "$id")"
        if [ -f "$cfile" ]; then
            while IFS='=' read -r k v; do
                [ -z "$k" ] && continue
                case "$k" in \#*) continue ;; esac
                ov="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$ov")"
            done < "$cfile"
        fi

        # overrides win
        printf '%s' "$base" | jq -c --argjson ov "$ov" \
            'map(if ($ov[.key] != null) then (.value = $ov[.key]) else . end)'
        ;;

    --set)
        id="$2"; key="$3"; value="$4"
        [ -z "$id" ] || [ -z "$key" ] && { echo "Usage: --set <id> <key> <value>" >&2; exit 1; }
        mkdir -p "$PROPS_DIR"
        cfile="$(props_file "$id")"
        touch "$cfile"
        if grep -q "^${key}=" "$cfile"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$cfile"
        else
            echo "${key}=${value}" >> "$cfile"
        fi
        ;;

    --reset)
        id="$2"
        rm -f "$(props_file "$id")"
        ;;

    --current)
        monitor="$2"
        conf="$hyprDir/wallpaper-daemon/config/$monitor/defaults.conf"
        [ -f "$conf" ] || exit 0
        settings="$HOME/.config/ags/cache/settings/settings.json"
        read_key() { grep "^$1=" "$conf" | cut -d'=' -f2- | head -n 1; }
        mode="workspace"; src="workspace1"
        if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
            m="$(jq -r '(.wallpaper.mode.value) // "workspace"' "$settings" 2>/dev/null)"
            [ -n "$m" ] && [ "$m" != "null" ] && mode="$m"
            s="$(jq -r '(.wallpaper.primarySource.value) // "workspace1"' "$settings" 2>/dev/null)"
            [ -n "$s" ] && [ "$s" != "null" ] && src="$s"
        fi
        ws="$(hyprctl monitors -j | jq -r --arg m "$monitor" '.[] | select(.name == $m) | .activeWorkspace.id')"
        if [ "$mode" = "global" ]; then wp="$(read_key global)"; else wp="$(read_key "w-${ws}")"; fi
        if [ -z "$wp" ]; then
            [ "$src" = "custom" ] && wp="$(read_key primary)"
            [ -z "$wp" ] && wp="$(read_key w-1)"
        fi
        case "$wp" in
            */workshop/content/431960/*)
                # id is the parent folder
                basename "$(dirname "$wp")"
                ;;
        esac
        ;;

    *)
        echo "Usage: $0 --list <id> | --set <id> <key> <value> | --reset <id> | --current <monitor>" >&2
        exit 1
        ;;
esac
