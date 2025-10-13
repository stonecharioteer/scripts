#!/usr/bin/env bash
#
# audible-ping.sh - Play an audible alert sound to draw attention
#
# Usage: audible-ping.sh [OPTIONS]
#
# A simple utility to play notification sounds from the command line.
# Useful for alerting when long-running commands complete, or as part
# of automation scripts that need to draw user attention.

set -euo pipefail

# Configuration
DEFAULT_SOUND="/usr/share/sounds/freedesktop/stereo/complete.oga"
LOUD_SOUND="/usr/share/sounds/freedesktop/stereo/suspend-error.oga"
DEFAULT_REPEAT=1
DEFAULT_INTERVAL=0.5

# Function to display help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Play an audible alert sound to draw attention to the computer.

OPTIONS:
    -h, --help              Show this help message
    -s, --sound PATH        Custom sound file to play (default: system complete sound)
    -r, --repeat COUNT      Number of times to repeat (default: 1)
    -i, --interval SECONDS  Interval between repeats in seconds (default: 0.5)
    -l, --list              List available system sounds
    -v, --volume PERCENT    Volume level 0-100 (paplay only, default: 100)
    --bell                  Use terminal bell instead of sound file
    --loud                  Use a louder, more attention-grabbing sound

EXAMPLES:
    # Simple ping
    $(basename "$0")

    # Louder, more attention-grabbing sound
    $(basename "$0") --loud

    # Repeat 3 times with 1 second interval
    $(basename "$0") -r 3 -i 1

    # Use terminal bell
    $(basename "$0") --bell

    # Custom sound file
    $(basename "$0") -s /path/to/sound.wav

    # Alert when command completes
    make build && $(basename "$0") -r 2 --loud

    # Lower volume
    $(basename "$0") -v 50

SOUND PLAYER PRIORITY:
    1. paplay (PulseAudio) - best compatibility
    2. ffplay (FFmpeg) - good fallback
    3. mpv - alternative player
    4. aplay (ALSA) - basic support

EOF
}

# Function to check available sound players
find_sound_player() {
    if command -v paplay &> /dev/null; then
        echo "paplay"
    elif command -v ffplay &> /dev/null; then
        echo "ffplay"
    elif command -v mpv &> /dev/null; then
        echo "mpv"
    elif command -v aplay &> /dev/null; then
        echo "aplay"
    else
        echo ""
    fi
}

# Function to play sound with detected player
play_sound() {
    local sound_file="$1"
    local player="$2"
    local volume="${3:-100}"

    case "$player" in
        paplay)
            paplay --volume=$((65536 * volume / 100)) "$sound_file" 2>/dev/null
            ;;
        ffplay)
            ffplay -nodisp -autoexit -volume "$volume" "$sound_file" 2>/dev/null
            ;;
        mpv)
            mpv --really-quiet --volume="$volume" "$sound_file" 2>/dev/null
            ;;
        aplay)
            aplay -q "$sound_file" 2>/dev/null
            ;;
        *)
            echo "Error: No supported sound player found" >&2
            echo "Please install one of: paplay, ffplay, mpv, aplay" >&2
            return 1
            ;;
    esac
}

# Function to list system sounds
list_system_sounds() {
    local sound_dirs=(
        "/usr/share/sounds/freedesktop/stereo"
        "/usr/share/sounds/gnome/default/alerts"
        "/usr/share/sounds/ubuntu/stereo"
        "/usr/share/sounds"
    )

    echo "Available system sounds:"
    echo
    for dir in "${sound_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            echo "From $dir:"
            find "$dir" -type f \( -name "*.oga" -o -name "*.ogg" -o -name "*.wav" -o -name "*.mp3" \) 2>/dev/null | head -10 | while read -r file; do
                echo "  $file"
            done
            echo
        fi
    done
}

# Function to find a working system sound
find_system_sound() {
    local candidates=(
        "/usr/share/sounds/freedesktop/stereo/complete.oga"
        "/usr/share/sounds/freedesktop/stereo/bell.oga"
        "/usr/share/sounds/freedesktop/stereo/message.oga"
        "/usr/share/sounds/gnome/default/alerts/bark.ogg"
        "/usr/share/sounds/ubuntu/stereo/message.ogg"
    )

    for sound in "${candidates[@]}"; do
        if [[ -f "$sound" ]]; then
            echo "$sound"
            return 0
        fi
    done

    # No system sound found
    return 1
}

# Function to find a loud system sound
find_loud_sound() {
    local candidates=(
        "/usr/share/sounds/freedesktop/stereo/suspend-error.oga"
        "/usr/share/sounds/freedesktop/stereo/phone-outgoing-calling.oga"
        "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
        "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"
        "/usr/share/sounds/freedesktop/stereo/bell.oga"
    )

    for sound in "${candidates[@]}"; do
        if [[ -f "$sound" ]]; then
            echo "$sound"
            return 0
        fi
    done

    # Fallback to regular sound
    find_system_sound
}

# Parse arguments
sound_file=""
repeat="$DEFAULT_REPEAT"
interval="$DEFAULT_INTERVAL"
use_bell=false
list_sounds=false
use_loud=false
volume=100

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--sound)
            sound_file="$2"
            shift 2
            ;;
        -r|--repeat)
            repeat="$2"
            shift 2
            ;;
        -i|--interval)
            interval="$2"
            shift 2
            ;;
        -l|--list)
            list_sounds=true
            shift
            ;;
        -v|--volume)
            volume="$2"
            shift 2
            ;;
        --bell)
            use_bell=true
            shift
            ;;
        --loud)
            use_loud=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Use -h or --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Handle list sounds request
if [[ "$list_sounds" == true ]]; then
    list_system_sounds
    exit 0
fi

# Validate volume
if [[ "$volume" -lt 0 || "$volume" -gt 100 ]]; then
    echo "Error: Volume must be between 0 and 100" >&2
    exit 1
fi

# Validate repeat count
if ! [[ "$repeat" =~ ^[0-9]+$ ]] || [[ "$repeat" -lt 1 ]]; then
    echo "Error: Repeat count must be a positive integer" >&2
    exit 1
fi

# Handle terminal bell
if [[ "$use_bell" == true ]]; then
    for ((i=1; i<=repeat; i++)); do
        printf '\a'
        if [[ $i -lt $repeat ]]; then
            sleep "$interval"
        fi
    done
    exit 0
fi

# Find sound file if not specified
if [[ -z "$sound_file" ]]; then
    if [[ "$use_loud" == true ]]; then
        if ! sound_file=$(find_loud_sound); then
            echo "Error: No system sounds found and no custom sound specified" >&2
            echo "Use --bell for terminal bell, or -s to specify a sound file" >&2
            exit 1
        fi
    else
        if ! sound_file=$(find_system_sound); then
            echo "Error: No system sounds found and no custom sound specified" >&2
            echo "Use --bell for terminal bell, or -s to specify a sound file" >&2
            exit 1
        fi
    fi
fi

# Validate sound file exists
if [[ ! -f "$sound_file" ]]; then
    echo "Error: Sound file not found: $sound_file" >&2
    exit 1
fi

# Find available sound player
player=$(find_sound_player)
if [[ -z "$player" ]]; then
    echo "Error: No supported sound player found" >&2
    echo "Please install one of: paplay (pulseaudio-utils), ffplay (ffmpeg), mpv, aplay (alsa-utils)" >&2
    exit 1
fi

# Play the sound
for ((i=1; i<=repeat; i++)); do
    if ! play_sound "$sound_file" "$player" "$volume"; then
        exit 1
    fi
    if [[ $i -lt $repeat ]]; then
        sleep "$interval"
    fi
done
