#!/bin/bash

# Define the file that contains the wallpaper paths
wallpaper_config="$HOME/.config/hypr/wallpaper-daemon/config"
wallpaper_folder="$HOME/.config/wallpapers"
thumbnail_folder="$HOME/.config/ags/cache/thumbnails"

# Initialize an empty array for the wallpaper paths
wallpaper_paths=()

generate_thumbnails() {
    local source_dir="$1"
    local thumb_dir="$2"
    
    # Ensure thumbnail directory exists
    mkdir -p "$thumb_dir"
    
    # Generate missing thumbnails in parallel, preserving folder structure
    find "$source_dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.gif" -o -iname "*.svg" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o -iname "*.mov" \) | while read -r wallpaper; do
        # Get relative path from source_dir to preserve folder structure
        relative_path="${wallpaper#$source_dir/}"
        relative_no_ext="${relative_path%.*}"
        thumbnail="$thumb_dir/$relative_no_ext.jpg"
        ext="${wallpaper##*.}"
        ext="${ext,,}"
        
        # Create subdirectory if needed
        mkdir -p "$(dirname "$thumbnail")"
        
        # Skip if thumbnail already exists
        if [ ! -f "$thumbnail" ]; then
            notify-send "Generating Wallpaper Thumbnail" "Generating wallpaper thumbnail for $relative_path" --expire-time=2000 --urgency=low
            case "$ext" in
                mp4|webm|mkv|mov)
                    ffmpeg -y -loglevel error -i "$wallpaper" -vf "thumbnail,scale=256:-1" -frames:v 1 "$thumbnail" >/dev/null 2>&1 &
                    ;;
                gif)
                    magick "${wallpaper}[0]" -resize 256x256 -quality 85 -strip "$thumbnail" >/dev/null 2>&1 &
                    ;;
                *)
                    magick "$wallpaper" -resize 256x256 -quality 85 -strip "$thumbnail" >/dev/null 2>&1 &
                    ;;
            esac
        fi
    done
    
    wait # Ensure all parallel processes finish before proceeding
    
    # Remove orphaned thumbnails
    find "$thumb_dir" -type f | while read -r thumb; do
        # Get relative path from thumb_dir to match with source structure
        relative_path="${thumb#$thumb_dir/}"

        # WE thumbs have no source here; the Workshop scan prunes them
        case "$relative_path" in wallpaperengine/*) continue ;; esac
        relative_no_ext="${relative_path%.*}"

        original_exists=false
        for ext in jpg jpeg png webp bmp gif svg mp4 webm mkv mov; do
            if [ -f "$source_dir/$relative_no_ext.$ext" ]; then
                original_exists=true
                break
            fi
        done

        # Delete thumbnail if original wallpaper is missing
        if [ "$original_exists" = false ]; then
            rm "$thumb"
        fi
    done
}

# check if $1 == current
if [ "$1" == "--current" ]; then
    # check if $2 is set
    if [ -z "$2" ]; then
        echo "Usage: get-wallpapers.sh --current <monitor>"
        exit 1
    else
        monitor=$2
    fi
    # Read the file line by line
    while IFS='=' read -r key path; do
        # Trim any whitespace from the path and add to the array
        path=$(echo "$path" | sed "s~^\$HOME~$HOME~" | xargs)
        wallpaper_paths+=("\"$path\"")
    done <"$wallpaper_config/$monitor/defaults.conf"

else

    # Find all directories containing images and preserve full relative path as category
    while IFS= read -r -d '' dir; do
        # Get relative path from wallpaper_folder to preserve full category path
        category="${dir#$wallpaper_folder/}"
        paths=()
        while IFS= read -r -d '' file; do
            paths+=("\"$file\"")
        done < <(find "$dir" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.gif" -o -iname "*.svg" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o -iname "*.mov" \) -print0)
        
        # Only add category if it has images
        if [ ${#paths[@]} -gt 0 ]; then
            wallpaper_paths+=("\"$category\": [$(IFS=,; echo "${paths[*]}")]")
        fi
    done < <(find "$wallpaper_folder" -type d -print0)

    # Wallpaper Engine items, from `kirie list`: it knows where Steam put
    # them and which the engine can actually render. Only those are listed.
    kirie_bin="$(command -v kirie 2>/dev/null)"
    [ -x "$kirie_bin" ] || kirie_bin="$HOME/.local/bin/kirie"
    if [ -x "$kirie_bin" ]; then
        we_paths=()
        we_types=()
        mkdir -p "$thumbnail_folder/wallpaperengine"
        while IFS=$'\t' read -r id preview wtype; do
            [ -n "$preview" ] || continue
            we_paths+=("\"$preview\"")
            we_types+=("\"$preview\": \"${wtype:-scene}\"")

            # keyed by item id, not by source path
            thumb="$thumbnail_folder/wallpaperengine/$id.jpg"
            if [ ! -f "$thumb" ]; then
                ext="${preview##*.}"; ext="${ext,,}"
                case "$ext" in
                    mp4|webm|mkv|mov) ffmpeg -y -loglevel error -i "$preview" -vf "thumbnail,scale=256:-1" -frames:v 1 "$thumb" >/dev/null 2>&1 & ;;
                    gif)              magick "${preview}[0]" -resize 256x256 -quality 85 -strip "$thumb" >/dev/null 2>&1 & ;;
                    *)                magick "$preview" -resize 256x256 -quality 85 -strip "$thumb" >/dev/null 2>&1 & ;;
                esac
            fi
        done < <("$kirie_bin" list --json 2>/dev/null |
            jq -r '.[] | select(.renderable and .preview != null) | [.id, .preview, .type] | @tsv')
        wait
        if [ ${#we_paths[@]} -gt 0 ]; then
            wallpaper_paths+=("\"wallpaperengine\": [$(IFS=,; echo "${we_paths[*]}")]")
            # Per-item WE type (scene/web/video/...), keyed by the listed path —
            # the switcher's badge reads this (__types) instead of guessing.
            wallpaper_paths+=("\"__types\": {$(IFS=,; echo "${we_types[*]}")}")
        fi
    fi

    # Generate thumbnails based on all wallpapers found
    generate_thumbnails "$wallpaper_folder" "$thumbnail_folder"
    
    # For categorized wallpapers, output as JSON object
    (IFS=,; echo "{${wallpaper_paths[*]}}")
    exit 0
fi

# For --current mode, output as JSON array
echo "[${wallpaper_paths[@]}]" | sed 's/" "/", "/g'
